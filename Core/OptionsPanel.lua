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
--
-- The layout: tabs across the top -- Mail tab, Send tab, Window, Minimap,
-- Mail Memory -- one list of settings under them, and beside the list an
-- inspector that says what the setting under the pointer does. Every row
-- reads the same way, the way Blizzard's own Settings panel reads: its
-- name on the left, its control on the right, every control in one column.
-- A feature's switch is its tab's first, larger row, and the rows it
-- governs grey with it. The two lists a player builds, character groups
-- and recipients, are tiles at the top of the inspector on the tab they
-- belong to. The drawing it was built from is .dev/design/options,
-- layout 3; one CSS pixel there is one UI unit here.
-- =====================================================================

ns.OptionsPanel = ns.OptionsPanel or {}
local Panel = ns.OptionsPanel

local L = ns.L

-- The bug report window's padding: the options panel's own card inset and
-- heading indent, which that window was built to match.
local PAD, CARD_PAD = 14, 10

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
    -- No preferredIndex: 12.x's StaticPopup does not read it. What puts the
    -- dialog above the options panel (FULLSCREEN_DIALOG strata) is the lift
    -- on every show (Theme.LiftPopup).
  }
  return true
end

-- The same offer on World of Warcraft: Forever, which refuses ReloadUI()
-- from addon code: the call above would raise Blizzard's "blocked" popup,
-- which names Postbox and offers to disable it. A /reload run by the
-- player's own click on a secure action button is the player's command,
-- not ours, and that the client allows. So there the offer is a card of
-- the house's (Theme.ApplyCard, which every style paints as one of Postbox's
-- popups) with the same words and answers, where a StaticPopup stands, and
-- its Reload now is covered by a button of Blizzard's
-- InsecureActionButtonTemplate whose click runs the macro "/reload". That
-- template acts out of combat only, so in combat the card offers OK alone,
-- and its words, which already say to type /reload, are the way; it follows
-- a fight that starts or ends while it is up (PLAYER_REGEN_DISABLED comes
-- before the lockdown). The template is not a protected one, so nothing here
-- is held by combat; the secure button is made all the same out of combat,
-- the first time the card shows there. The card goes with the options panel
-- (PanelHide), which asks every offer. Retail never builds any of it.
local ReloadAsk = {}
do
  local CARD = { W = 320, PAD = 16, GAP = 14, BUTTON_H = 22, BUTTON_GAP = 8 }
  CARD.PAIR = { height = CARD.BUTTON_H, gap = CARD.BUTTON_GAP, minWidth = 96 }
  CARD.ONE = { height = CARD.BUTTON_H, minWidth = 96 }
  local card

  -- The visible button keeps its look: the secure one over it hands on
  -- the pointer's hover and press.
  local function SecureEnter(self)
    local shown = self:GetParent()
    shown:LockHighlight()
    local enter = shown:GetScript("OnEnter")
    if enter then enter(shown) end
  end
  local function SecureLeave(self)
    local shown = self:GetParent()
    shown:UnlockHighlight()
    shown:SetButtonState("NORMAL")
    local leave = shown:GetScript("OnLeave")
    if leave then leave(shown) end
  end
  local function SecureDown(self) self:GetParent():SetButtonState("PUSHED") end
  local function SecureUp(self) self:GetParent():SetButtonState("NORMAL") end

  -- Over Reload now, made once. Released clicks only, and said so: left
  -- unset, the template acts on the press whenever the game's key-down
  -- setting is on, and a release-only button never delivers one.
  local function Secure(c)
    if c.Secure then return c.Secure end
    local shown = c.Reload
    local b = CreateFrame("Button", nil, shown, "InsecureActionButtonTemplate")
    b:SetAllPoints(shown)
    b:SetFrameLevel(shown:GetFrameLevel() + 5)
    b:RegisterForClicks("LeftButtonUp")
    b:SetAttribute("useOnKeyDown", false)
    b:SetAttribute("type", "macro")
    b:SetAttribute("macrotext", "/reload")
    b:SetScript("OnEnter", SecureEnter)
    b:SetScript("OnLeave", SecureLeave)
    b:SetScript("OnMouseDown", SecureDown)
    b:SetScript("OnMouseUp", SecureUp)
    c.Secure = b
    return b
  end

  local function Build()
    local T = ns.Theme
    local c = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    -- The options panel's strata, raised on every show: over the panel, as
    -- the lifted popup is.
    c:SetFrameStrata("FULLSCREEN_DIALOG")
    c:SetToplevel(true)
    c:SetClampedToScreen(true)
    c:EnableMouse(true)
    c:SetPoint("TOP", UIParent, "TOP", 0, -135)
    c:Hide()
    -- A popup: solid at any window opacity.
    c.__pbPopupAlways = true
    c.__pbEuiAlwaysOpaque = true
    T.ApplyCard(c)
    c:SetScript("OnEvent", ReloadAsk.OnEvent)
    c:HookScript("OnHide", ReloadAsk.Hidden)

    local text = T.CreateText(c, "body")
    text:SetJustifyH("CENTER")
    text:SetWordWrap(true)
    text:SetText(L["MSG_STYLE_RELOAD"])
    local reload = T.CreateButton(nil, c)
    reload:SetText(L["BTN_RELOAD_NOW"])
    local later = T.CreateButton(nil, c)
    later:SetText(L["BTN_LATER"])
    later:SetScript("OnClick", ReloadAsk.Hide)
    local ok = T.CreateButton(nil, c)
    ok:SetText(L["POPUP_OK"])
    ok:SetScript("OnClick", ReloadAsk.Hide)
    c.Text, c.Reload, c.Later, c.OK = text, reload, later, ok
    c.Pair = { reload, later }
    return c
  end

  -- Measured on every paint: the skin may have re-fonted the buttons. Out
  -- of combat Reload now and Later, side by side as a StaticPopup's; in
  -- combat OK alone.
  local function Paint(c, combat)
    local T = ns.Theme
    local P = CARD
    local _, pair = T.SizeRow(c.Pair, P.PAIR)
    T.SizeToText(c.OK, P.ONE)
    local width = math.max(P.W, pair + 2 * P.PAD)
    local text = c.Text
    text:ClearAllPoints()
    text:SetPoint("TOP", c, "TOP", 0, -P.PAD)
    text:SetWidth(width - 2 * P.PAD)
    local textH = math.ceil(text:GetStringHeight() or 12)
    c:SetSize(width, P.PAD + textH + P.GAP + P.BUTTON_H + P.PAD)

    if not combat then Secure(c) end
    c.Reload:ClearAllPoints()
    c.Reload:SetPoint("BOTTOMRIGHT", c, "BOTTOM", -P.BUTTON_GAP / 2, P.PAD)
    c.Later:ClearAllPoints()
    c.Later:SetPoint("BOTTOMLEFT", c, "BOTTOM", P.BUTTON_GAP / 2, P.PAD)
    c.OK:ClearAllPoints()
    c.OK:SetPoint("BOTTOM", c, "BOTTOM", 0, P.PAD)
    c.Reload:SetShown(not combat)
    c.Later:SetShown(not combat)
    c.OK:SetShown(combat)
  end

  function ReloadAsk.Show()
    card = card or Build()
    local skin = ns.Skin
    if skin and skin.Refresh then pcall(skin.Refresh, card) end
    card:RegisterEvent("PLAYER_REGEN_DISABLED")
    card:RegisterEvent("PLAYER_REGEN_ENABLED")
    card:Show()
    card:Raise()
    Paint(card, InCombatLockdown() and true or false)
  end

  function ReloadAsk.Hide()
    if card then card:Hide() end
  end

  -- A fight began (before the lockdown) or ended while the card is up.
  function ReloadAsk.OnEvent(self, event)
    Paint(self, event == "PLAYER_REGEN_DISABLED")
  end

  function ReloadAsk.Hidden(self)
    self:UnregisterEvent("PLAYER_REGEN_DISABLED")
    self:UnregisterEvent("PLAYER_REGEN_ENABLED")
  end
end

-- After a style change: the offer to reload, on either client.
local function OfferStyleReload()
  if ns.IsForever then
    ReloadAsk.Show()
  elseif EnsureStyleDialog() then
    ns.Theme.LiftPopup(StaticPopup_Show(POPUP_STYLE_RELOAD))
  else
    ns.Print(L["MSG_STYLE_RELOAD"])
  end
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
  if by == "postbox" then return nil end

  -- Nothing has been painted yet, so fall back to who holds the skin slot.
  --
  -- The style choice has to be consulted FIRST. This used to read "ns.Skin is
  -- set and a host global exists, therefore the host is painting", which was
  -- sound only while a host skin was the only thing that could claim with one
  -- installed. The Postbox style can claim over a host, and on that session
  -- the old test named the host as the painter -- so the panel would have
  -- reported inheriting, in green, while the Postbox style was on screen.
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
-- The bug report window
--
-- Where to report, the report to paste, and the one switch that decides how
-- much the report can say about a slow mailbox. A window of the house's own
-- kind -- the options panel's, the groups editor's: the template, the
-- theme, whichever skin paints those -- where it used to be a bare black box
-- that ran its text past its own edges and belonged to no skin.
--
-- A fixed size. What sits above and below the report is measured on every
-- open (a translation can wrap the recording note onto another line) and the
-- report takes the height that is left; only if that would fall below a
-- readable minimum does the window grow.
--
-- Nothing in the game can open a browser or write the clipboard, so copyable
-- is the whole feature: both fields select everything on a click or on
-- focus, and Copy report selects the report with the keyboard in it, one
-- Ctrl+C from done.
-------------------------------------------------------------
local BugReport = {}
do
  local BUG_URL = "https://github.com/egsherlock/Postbox/issues"
  local WIN_W, WIN_H = 500, 440
  local TOP = 30            -- under the template's title bar
  local LINE_H = 22         -- a heading line, with room for a control on it
  local BOX_MIN = 140       -- the least of the report worth showing
  local MODES = { "off", "on", "detail" }
  local MODE_KEY = { off = "PERF_REC_OFF", on = "PERF_REC_ON", detail = "PERF_REC_DETAIL" }
  local MODE_DESC = { off = "PERF_REC_OFF_DESC", on = "PERF_REC_ON_DESC", detail = "PERF_REC_DETAIL_DESC" }

  local win

  -- An edit box that can be selected and copied from but not changed: any
  -- edit snaps the text back and selects it again, so Ctrl+C always copies
  -- the intact value. OnTextChanged rather than OnChar: Backspace, Delete and
  -- Enter change the text without ever firing OnChar. The flag stops the
  -- restore re-entering itself. Flagged for the skins as the options' own
  -- boxes are: the surface around it is the field, not the box.
  local function ReadOnly(box)
    local T = ns.Theme
    box:SetAutoFocus(false)
    box.__postboxNoEditSkin = true
    T.SetBoxFont(box, T.FontObject("bodySmall") or GameFontHighlightSmall)
    T.SetColor(box, "textPrimary")
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnEditFocusLost", function(self) self:HighlightText(0, 0) end)
    box:SetScript("OnMouseUp", function(self) self:HighlightText() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnTextChanged", function(self, userInput)
      if not userInput or self._restoring then return end
      self._restoring = true
      self:SetText(self._value or "")
      self._restoring = false
      self:HighlightText()
    end)
  end

  local function Tip(owner, title, desc)
    owner:HookScript("OnEnter", function(self)
      local T = ns.Theme
      T.TipBegin(self, "ANCHOR_RIGHT")
      T.TipTitle(type(title) == "function" and title(self) or title)
      T.TipLine(type(desc) == "function" and desc(self) or desc)
      GameTooltip:Show()
    end)
    owner:HookScript("OnLeave", function() GameTooltip:Hide() end)
  end

  -- A heading line across the window: the caption at the options panel's
  -- heading indent, room on the right for a hint or a control. `anchor` is
  -- the field above it, which spans the window less 10 either side, as the
  -- options panel's cards do.
  local function HeadingLine(f, anchor, gap, key)
    local line = CreateFrame("Frame", nil, f)
    line:SetHeight(LINE_H)
    if anchor then
      line:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", PAD - 10, -gap)
      line:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 10 - PAD, -gap)
    else
      line:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -TOP)
      line:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -TOP)
    end
    local caption = ns.Theme.CreateText(line, "heading")
    caption:SetPoint("LEFT", line, "LEFT", 0, 0)
    caption:SetWordWrap(false)
    caption:SetText(L[key])
    line.Caption = caption
    return line
  end

  local function Build()
    local T = ns.Theme
    local M = T.Metrics

    -- Named: Escape closes it through UISpecialFrames, a list of names.
    local f = CreateFrame("Frame", "PostboxBugReportFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(WIN_W, WIN_H)
    -- The options panel's strata, raised above it on every open, as the
    -- groups editor is.
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    -- Read to the letter, so opaque whatever the mailbox window's opacity.
    -- Skin.ApplyBgOpacity honours this flag.
    f.__pbEuiAlwaysOpaque = true
    if f.SetTitle then
      f:SetTitle(L["OPT_BUG_TIP_TITLE"])
    elseif f.TitleText then
      f.TitleText:SetText(L["OPT_BUG_TIP_TITLE"])
    end
    T.ApplyFrameTheme(f)
    ns.Core.UI.Helpers.RegisterEscClose(f)

    -- 1. Where: the address, in a field of its own, and how to copy it.
    local urlLine = HeadingLine(f, nil, 0, "OPT_BUG_URL_LABEL")
    local hint = T.CreateText(urlLine, "secondary")
    hint:SetPoint("RIGHT", urlLine, "RIGHT", 0, 0)
    hint:SetJustifyH("RIGHT")
    -- Motion only, for the rare translation the line cuts short: a click
    -- passes on, so the window still drags from here.
    urlLine:EnableMouse(true)
    if urlLine.SetPropagateMouseClicks then urlLine:SetPropagateMouseClicks(true) end
    urlLine:SetScript("OnEnter", function(self)
      if not self.__pbOverflowText then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      T.AddOverflowLine(self, GameTooltip)
      GameTooltip:Show()
    end)
    urlLine:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local urlWrap = CreateFrame("Frame", nil, f, "BackdropTemplate")
    urlWrap:SetPoint("TOPLEFT", urlLine, "BOTTOMLEFT", 10 - PAD, -M.labelGap)
    urlWrap:SetPoint("TOPRIGHT", urlLine, "BOTTOMRIGHT", PAD - 10, -M.labelGap)
    urlWrap:SetHeight(M.controlHeight)
    local url = CreateFrame("EditBox", nil, urlWrap)
    T.StyleInput(urlWrap, url)
    url:SetPoint("TOPLEFT", urlWrap, "TOPLEFT", 8, -2)
    url:SetPoint("BOTTOMRIGHT", urlWrap, "BOTTOMRIGHT", -8, 2)
    ReadOnly(url)
    url:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    urlWrap:SetScript("OnMouseDown", function() url:SetFocus() end)

    -- 2. What: the report, and the one click that selects it.
    local reportLine = HeadingLine(f, urlWrap, M.gap, "OPT_BUG_DIAG_LABEL")
    local copy = T.CreateButton(nil, reportLine)
    copy:SetPoint("RIGHT", reportLine, "RIGHT", 0, 0)
    copy:SetText(L["OPT_BUG_COPY"])
    copy:SetScript("OnClick", function() BugReport.SelectReport() end)
    Tip(copy, L["OPT_BUG_COPY"], L["OPT_BUG_COPY_DESC"])

    local card = CreateFrame("Frame", nil, f, "BackdropTemplate")
    card:SetPoint("TOPLEFT", reportLine, "BOTTOMLEFT", 10 - PAD, -M.labelGap)
    card:SetPoint("TOPRIGHT", reportLine, "BOTTOMRIGHT", PAD - 10, -M.labelGap)
    T.ApplyList(card)

    -- The gutter is the report's for good, bar or no bar, so the bar
    -- arriving never re-flows the text being read (the Send tab's body does
    -- the same). The scroll frame clips: whatever a line holds, nothing is
    -- drawn outside the card.
    local gutter = M.scrollGutter
    local scroll = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -6)
    scroll:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -gutter, 6)
    if scroll.SetClipsChildren then scroll:SetClipsChildren(true) end
    scroll.scrollBarHideable = 1
    T.SlimScrollBar(scroll, card)

    -- A multi-line edit box sizes its own height to its text, and wraps at
    -- its width: the scroll frame's, followed on every size change.
    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetWidth(WIN_W - 20 - 8 - gutter)
    ReadOnly(box)
    scroll:SetScrollChild(box)
    scroll:HookScript("OnSizeChanged", function(_, width)
      if width and width > 10 and math.abs((box:GetWidth() or 0) - width) > 0.5 then
        box:SetWidth(width)
      end
    end)
    -- Arrowing through the text keeps the cursor's line in view.
    box:SetScript("OnCursorChanged", function(_, _, cursorY, _, cursorH)
      local view = scroll:GetHeight() or 0
      local offset = scroll:GetVerticalScroll() or 0
      local top = -(tonumber(cursorY) or 0)
      local bottom = top + (tonumber(cursorH) or 0)
      local range = scroll:GetVerticalScrollRange() or 0
      if top < offset then
        scroll:SetVerticalScroll(math.max(0, top))
      elseif bottom > offset + view then
        scroll:SetVerticalScroll(math.min(range, bottom - view))
      end
    end)

    -- 3. How much: the recording switch, in a card at the foot like the
    -- options panel's own.
    local rec = CreateFrame("Frame", nil, f, "BackdropTemplate")
    rec:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 10)
    rec:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
    T.ApplyList(rec)
    card:SetPoint("BOTTOMLEFT", rec, "TOPLEFT", 0, M.sectionGap)
    card:SetPoint("BOTTOMRIGHT", rec, "TOPRIGHT", 0, M.sectionGap)

    local recLabel = T.CreateText(rec, "label")
    recLabel:SetWordWrap(false)
    recLabel:SetText(L["PERF_REC_TITLE"])
    local segments = {}
    for i = 1, #MODES do
      local seg = T.CreatePlate(rec, "segment")
      seg.mode = MODES[i]
      seg:SetText(L[MODE_KEY[seg.mode]])
      seg:SetScript("OnClick", function(self) BugReport.SetMode(self.mode) end)
      Tip(seg, function(self) return L[MODE_KEY[self.mode]] end,
        function(self) return L[MODE_DESC[self.mode]] end)
      segments[i] = seg
    end
    local note = T.CreateText(rec, "secondary")
    note:SetJustifyH("LEFT")
    note:SetWordWrap(true)
    note:SetText(L["PERF_REC_DESC"])

    -- Closing lets go of the keyboard, wherever it was.
    f:SetScript("OnHide", function()
      url:ClearFocus()
      box:ClearFocus()
      GameTooltip:Hide()
    end)

    f.UrlLine, f.Hint, f.Url = urlLine, hint, url
    f.ReportLine, f.Copy, f.Scroll, f.Report = reportLine, copy, scroll, box
    f.RecCard, f.RecLabel, f.Segments, f.RecNote = rec, recLabel, segments, note
    return f
  end

  -- Measured on every open: a host skin re-fonts the button after build,
  -- and every caption here is a translation. Only the edge cases move --
  -- the hint is cut where a caption would reach it, and the recording
  -- label takes a line of its own where it and the switch cannot share one.
  local function Layout(f)
    local T = ns.Theme
    local M = T.Metrics
    local lineW = WIN_W - 2 * PAD
    T.FitText(f.Hint, lineW - math.ceil(T.TextWidth(f.UrlLine.Caption)) - M.gap,
      L["OPT_BUG_HINT"], f.UrlLine)
    T.SizeToText(f.Copy, { height = LINE_H, minWidth = 96 })

    local rec, label, segments = f.RecCard, f.RecLabel, f.Segments
    local inner = WIN_W - 20 - 2 * CARD_PAD
    local gap = M.space.snug
    local per, total = T.SizeRow(segments, { height = M.segmentHeight, gap = gap, minWidth = M.buttonMinWidth })
    local labelW = math.ceil(T.TextWidth(label))
    local y = -CARD_PAD
    local x = CARD_PAD
    label:ClearAllPoints()
    if labelW + M.gap + total > inner then
      label:SetPoint("TOPLEFT", rec, "TOPLEFT", CARD_PAD, y)
      y = y - math.ceil(label:GetStringHeight() or 12) - M.gap
    else
      label:SetPoint("LEFT", rec, "TOPLEFT", CARD_PAD, y - M.segmentHeight / 2)
      x = CARD_PAD + inner - total
    end
    for i = 1, #segments do
      local seg = segments[i]
      seg:ClearAllPoints()
      seg:SetPoint("TOPLEFT", rec, "TOPLEFT", x + (i - 1) * (per + gap), y)
    end
    y = y - M.segmentHeight - M.gap

    local note = f.RecNote
    note:ClearAllPoints()
    note:SetPoint("TOPLEFT", rec, "TOPLEFT", CARD_PAD, y)
    note:SetWidth(inner)
    y = y - math.ceil(note:GetStringHeight() or 12) - CARD_PAD
    rec:SetHeight(-y)

    -- The report takes what is left, down to its minimum.
    local above = TOP + LINE_H + M.labelGap + M.controlHeight + M.gap + LINE_H + M.labelGap
    local below = M.sectionGap - y + 10
    f:SetHeight(math.max(WIN_H, above + BOX_MIN + below))
  end

  -- The recording switch, painted from what is live.
  local function Paint(f)
    local get = ns.GetPerfRecording
    local mode = type(get) == "function" and get() or "off"
    for i = 1, #f.Segments do
      local seg = f.Segments[i]
      ns.Theme.SetPlateSelected(seg, seg.mode == mode)
    end
  end

  -- The report, afresh. Built here and only here: it reads the game's
  -- profiler and every addon's memory, which is the report's own cost.
  local function Fill(f)
    local build = ns.BuildDiagnosticReport
    local ok, text = false, nil
    -- A report given to it (/postbox debug text) stands while it is open.
    if f._given then
      ok, text = true, f._given
    elseif type(build) == "function" then
      ok, text = pcall(build)
    end
    if not ok or type(text) ~= "string" then text = "" end
    local box = f.Report
    box._value = text
    box:SetText(text)
    box:SetCursorPosition(0)
    f.Scroll:SetVerticalScroll(0)
  end

  -- Beside the options panel when it is up -- the side with room, right
  -- first, level with its foot, where the line that opens this sits --
  -- else the middle of the screen. The groups editor's rule.
  local function Place(f, panel)
    f:ClearAllPoints()
    local left = panel and panel:IsShown() and panel:GetLeft()
    local right = left and panel:GetRight()
    if not (left and right) then
      f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
      return
    end
    local scale = panel:GetEffectiveScale() or 1
    local own = (f:GetWidth() or WIN_W) * (f:GetEffectiveScale() or 1)
    local screen = (UIParent:GetRight() or 0) * (UIParent:GetEffectiveScale() or 1)
    if right * scale + 8 + own > screen and left * scale - 8 - own >= 0 then
      f:SetPoint("BOTTOMRIGHT", panel, "BOTTOMLEFT", -8, 0)
    else
      f:SetPoint("BOTTOMLEFT", panel, "BOTTOMRIGHT", 8, 0)
    end
  end

  -- `panel`: the options panel, which takes this window with it when it
  -- closes.
  local function Open(panel)
    win.Url._value = BUG_URL
    win.Url:SetText(BUG_URL)
    win.Url:SetCursorPosition(0)
    Layout(win)
    Paint(win)
    Fill(win)
    Place(win, panel)
    win:Show()
    win:Raise()
    if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, win) end
    -- The address arrives focused and selected: Ctrl+C is all it needs.
    win.Url:SetFocus()
  end

  local function Ensure(panel)
    if win then return end
    win = Build()
    if panel then panel:HookScript("OnHide", function() win:Hide() end) end
    -- A report given to it lasts until it closes.
    win:HookScript("OnHide", function(self) self._given = nil end)
    -- The same expression as the options panel and the groups editor.
    local applyWindow = ns.Skin and (ns.Skin.ApplyWindow or ns.Skin.Apply)
    if applyWindow then applyWindow(win) end
  end

  function BugReport.Toggle(panel)
    Ensure(panel)
    if win:IsShown() then
      win:Hide()
      return
    end
    Open(panel)
  end

  -- The window with `text` in the report's place (/postbox debug text),
  -- opened, or filled again where it is open.
  function BugReport.ShowText(panel, text)
    Ensure(panel)
    win._given = text or ""
    if win:IsShown() then
      Fill(win)
    else
      Open(panel)
    end
  end

  -- Copy report: everything selected, the keyboard in the box.
  function BugReport.SelectReport()
    if not win then return end
    win.Report:SetFocus()
    win.Report:HighlightText()
  end

  -- A segment's click. The report is built again only when the choice
  -- changed, so it says what is recording now.
  function BugReport.SetMode(mode)
    local set, get = ns.SetPerfRecording, ns.GetPerfRecording
    if type(set) ~= "function" or type(get) ~= "function" then return end
    local before = get()
    set(mode)
    if not win then return end
    Paint(win)
    if get() ~= before and win:IsShown() then Fill(win) end
  end

  -- The options panel's refresh, on every open and after a reset: the
  -- record follows the saved choice (a reset clears it), and the switch is
  -- painted from it.
  function BugReport.Sync()
    local set, get = ns.SetPerfRecording, ns.GetPerfRecording
    if type(set) ~= "function" or type(get) ~= "function" then return end
    local before = get()
    set()
    if not win then return end
    Paint(win)
    if get() ~= before and win:IsShown() then Fill(win) end
  end
end

-------------------------------------------------------------
-- Geometry
--
-- The drawing's numbers: a 34-unit title, a row of 26-unit tabs, the
-- 400-unit list beside the 240-unit inspector, 10 between each, and the
-- footer band. A list row is 28 units, a feature's switch 30, a group's
-- heading 26.
-------------------------------------------------------------
local PANEL_W = 670
local EDGE, TOP = 10, 34
local TAB_H, TAB_GAP, BODY_GAP = 26, 4, 10
local LIST_W, INSP_W = 400, 240
-- Inside the list's one-unit edge: the width a row has, and the list's own
-- padding over its first row and under its last.
local ROW_W, LIST_PAD = LIST_W - 2, 4
local ROW_H, MASTER_H, GROUP_H = 28, 30, 26
-- A row's name stands NAME_X in from its left, its control CONTROL_R in
-- from its right, and the two keep at least NAME_GAP apart.
local NAME_X, CONTROL_R, NAME_GAP = 12, 10, 8
local CHECK_H, BUTTON_H = 22, 22
-- A dropdown's toggle (wider only where its widest value needs it,
-- Rows.Fit), and the narrowest a long translated name may squeeze it to
-- before the name itself is cut short.
local DD_W, DD_H, DD_MIN_W = 165, 22, 120
local BAND_H, FOOT_BOTTOM = 24, 14
-- The inspector: its drawings stand CTX_X in (its edge and ten), and its
-- text has the padding below.
local CTX_X = 11
local CTX_W = INSP_W - 2 * CTX_X
local TEXT_X, TEXT_TOP, TEXT_BOTTOM, TEXT_GAP = 12, 9, 11, 4
local TEXT_W = INSP_W - 2 - 2 * TEXT_X
-- The text zone is never shorter than this: most descriptions fit it, so
-- the text does not jump as the pointer moves from setting to setting.
local SAY_MIN = 150
-- STAGE: the Minimap drawing's ground at its least (Ctx.MinimapStage).
local TILE_H, HOST_H, STAGE, MOCK_H = 46, 32, 120, 34
-- The accent row's reading under its description: its lines.
local READOUT_LINES = 3
local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"
local GLOW_TGA = "Interface\\AddOns\\Postbox\\Media\\minimap-glow.tga"
local ROUND_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
-- Hairlines between rows and the wash under the row the pointer is on:
-- chrome, so white at a low alpha.
local HAIR_A, WASH_A = 0.08, 0.05
-- A plain 1-unit frame for Postbox's own drawings, which no skin repaints.
local PLAIN_BACKDROP = {
  bgFile = WHITE, edgeFile = WHITE, edgeSize = 1,
  insets = { left = 1, right = 1, top = 1, bottom = 1 },
}
-- A push button's size, from its caption: 14 each side of it.
local BUTTON_FIT = { height = BUTTON_H, padding = 28, minWidth = 64 }

local TABS = {
  { key = "mail",    caption = "OPT_MAILTAB_HEADING" },
  { key = "send",    caption = "OPT_SENDTAB_HEADING" },
  { key = "window",  caption = "OPT_WINDOW_HEADING" },
  { key = "minimap", caption = "OPT_MINIMAP_HEADING", square = true },
  { key = "memory",  caption = "OPT_MEMORY_TITLE",    square = true },
}

-- Everything the panel keeps between calls, on one table.
local S = {
  cells = {},     -- every row, or half-row, the pointer can rest on
  entries = {},   -- every title and text the inspector can show
  groups = {},    -- the group headings, whose rules are measured
  pairs = {},     -- the rows of two checkboxes, which come apart to fit
  cols = {},      -- tab key -> its page's column (Rows.Column)
  pageH = {},     -- tab key -> its page's height
  tabNeed = {},   -- each tab's measured need, and whether it is held to it
  tabFixed = {},
  refresh = {},   -- run on every open and after a reset
  idle = {},      -- tab key -> what the inspector says at rest
  pages = {},     -- tab key -> its page of the list
  tabCells = {},  -- tab key -> { first, last }: its rows' place in `cells`
  plates = {},    -- tab key -> its tab
  ctx = {},       -- tab key -> its drawing, once built
  tiles = {},     -- the drawings' tiles (Character Groups, Manage Recipients)
  tab = "mail",
  shown = false,  -- the entry the inspector's text zone shows (nil: at rest)
  -- held: the row whose dropdown's list is open; heldAt and heldEnter, where
  -- the pointer rests meanwhile (Rows.Hold)
  bodyH = 0,
  textGen = 0,    -- counts changes to a text the inspector can show
}

-- The sections below, declared together so each can reach the others.
local Tip, Insp, Ctx, Rows, Tabs, Pages, State, Footer = {}, {}, {}, {}, {}, {}, {}, {}

-- title, text [, extra]: one thing the inspector can say. `extra` names a
-- drawing shown under the text ("arrange").
local function Entry(title, text, extra)
  local entry = { title = title, text = text, extra = extra }
  S.entries[#S.entries + 1] = entry
  return entry
end

-- A caption's width with nothing holding it in.
local function TextW(fs)
  if not fs then return 0 end
  local w = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
  return math.ceil(tonumber(w) or 0)
end

-------------------------------------------------------------
-- Tooltips
--
-- Every control keeps a tooltip, as in every Postbox window: its name and
-- the summary of its description, the paragraph before its first blank
-- line (Locales.lua, ns.Summary) -- the inspector beside it says the
-- whole. It stands beside the panel, level with the control, on the side
-- with room: over the panel it would cover the inspector.
-------------------------------------------------------------

-- Begun as the house's (Theme section 5b): the title white, what the
-- control does bright under it.
function Tip.Begin(owner, title, text)
  local T = ns.Theme
  local tip = T.TipBegin(owner, "ANCHOR_NONE")
  T.TipTitle(title or "")
  T.TipLine(text)
  return tip
end

function Tip.Show(owner)
  local tip, frame = GameTooltip, S.frame
  tip:Show()
  if not frame then return end
  local fs = frame:GetEffectiveScale() or 1
  local ts = tip:GetEffectiveScale() or 1
  local own = owner:GetEffectiveScale() or fs
  local top, ftop = owner:GetTop(), frame:GetTop()
  local left, right = frame:GetLeft(), frame:GetRight()
  tip:ClearAllPoints()
  if not (top and ftop and left and right) then
    tip:SetPoint("BOTTOMLEFT", owner, "TOPRIGHT", 0, 0)
    return
  end
  local dy = (top * own - ftop * fs) / ts
  local width = (tip:GetWidth() or 0) * ts
  local screen = (UIParent:GetRight() or 0) * (UIParent:GetEffectiveScale() or 1)
  if right * fs + 6 * ts + width > screen and left * fs - 6 * ts - width >= 0 then
    tip:SetPoint("TOPRIGHT", frame, "TOPLEFT", -6, dy)
  else
    tip:SetPoint("TOPLEFT", frame, "TOPRIGHT", 6, dy)
  end
end

function Tip.Entry(owner, entry)
  if not entry then return end
  local tip = Tip.Begin(owner, entry.title, ns.Summary(entry.text))
  -- A dropdown's value cut short in its box (Lib/UI/Dropdown.lua) is said
  -- whole under what the setting does.
  if owner.__postboxSelect and owner.__pbOverflowText then ns.Theme.AddOverflowLine(owner, tip) end
  Tip.Show(owner)
end

-------------------------------------------------------------
-- The inspector
--
-- A card beside the list, in two zones. The top is the tab's own drawing
-- (Ctx, below): what the tab builds or opens, or what its settings look
-- like. The foot is text: the tab's own description at rest, and while the
-- pointer is on a setting that setting's description -- on a raised card
-- over the foot, which grows up over the drawing only for a description
-- that needs the room.
--
-- Calm, by one rule: the text follows the pointer from setting to setting,
-- and stays on the last one while the pointer is anywhere over the list or
-- the inspector -- a group's heading, the hairline between two rows, on its
-- way across to read a long description. It goes back to the tab's own
-- when the pointer leaves them both, or the tab changes. Crossing the list
-- never flashes the tab's text between two rows. While a dropdown's list is
-- open the text stays on that dropdown's row, wherever the pointer goes
-- (Rows.Hold).
--
-- A hover allocates nothing: every text is a string its entry already
-- holds and every region exists, so a hover sets text, a height and what
-- is shown.
-------------------------------------------------------------
do
  local function TextBlock(block)
    local T = ns.Theme
    local title = T.CreateText(block, "body")
    title:SetPoint("TOPLEFT", block, "TOPLEFT", TEXT_X, -TEXT_TOP)
    title:SetWidth(TEXT_W)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(true)
    local text = T.CreateText(block, "secondary")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -TEXT_GAP)
    text:SetWidth(TEXT_W)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(true)
    if text.SetSpacing then text:SetSpacing(2) end
    block.Title, block.Text = title, text
  end

  -- A title and a text into `block`, and the height they take with its
  -- padding and `extraH` more kept under the text.
  local function Lay(block, title, text, extraH)
    local t, d = block.Title, block.Text
    t:SetText(title or "")
    local h = TEXT_TOP + math.ceil(t:GetStringHeight() or 0)
    if text and text ~= "" then
      d:SetText(text)
      d:Show()
      h = h + TEXT_GAP + math.ceil(d:GetStringHeight() or 0)
    else
      d:SetText("")
      d:Hide()
    end
    return h + (extraH or 0) + TEXT_BOTTOM
  end

  function Insp.Build(card)
    local T = ns.Theme

    -- At rest: the tab's own text, under a hairline.
    local idle = CreateFrame("Frame", nil, card)
    idle:SetFrameLevel(card:GetFrameLevel() + 2)
    idle:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 1, 1)
    idle:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -1, 1)
    idle:SetHeight(SAY_MIN)
    TextBlock(idle)
    local rule = idle:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", idle, "TOPLEFT", 0, 0)
    rule:SetPoint("TOPRIGHT", idle, "TOPRIGHT", 0, 0)
    T.FillChrome(rule, HAIR_A)
    idle.Rule = rule
    S.idleBlock = idle

    -- Pointed at: a card of its own over the foot, above the drawings. A
    -- declared popup, so it keeps the opacity floor whatever a skin paints
    -- over it: the drawing it covers never shows through the text.
    local say = CreateFrame("Frame", nil, card, "BackdropTemplate")
    say:SetFrameLevel(card:GetFrameLevel() + 20)
    say:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 0, 0)
    say:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", 0, 0)
    say:SetHeight(SAY_MIN)
    say.__pbPopupAlways = true
    T.ApplyCard(say)
    TextBlock(say)
    say:Hide()
    S.say = say

    -- Where every text is measured: the same roles at the same width.
    local measure = CreateFrame("Frame", nil, card)
    measure:SetPoint("TOPLEFT", card, "TOPLEFT", 0, 0)
    measure:SetSize(INSP_W, 10)
    TextBlock(measure)
    -- And a drawing's caption, at the width it is given (Ctx.MeasureCaptions).
    measure.Cap = Ctx.Caption(measure)
    measure:Hide()
    S.measure = measure
  end

  -- entry, or nil for the tab's own text.
  function Insp.Show(entry)
    if entry == S.shown then return end
    S.shown = entry
    -- A drawing that answers the setting pointed at follows it.
    Ctx.Follow()
    local say, idle = S.say, S.idleBlock
    if not say then return end
    if not entry then
      say:Hide()
      idle:Show()
      return
    end
    local extra = entry.extra and Ctx.Extra(entry.extra) or nil
    local was = S.extraShown
    if was and was ~= extra then was:Hide() end
    S.extraShown = extra
    -- Shown before it is measured, in the same frame: nothing is drawn in
    -- between, and the text lays out on a shown card.
    say:Show()
    idle:Hide()
    local h = Lay(say, entry.title, entry.text, extra and extra.height or 0)
    if extra then extra:Show() end
    local least = Insp.Least(S.tab)
    if h < least then h = least end
    if S.bodyH > 0 and h > S.bodyH then h = S.bodyH end
    say:SetHeight(h)
  end

  -- The text zone's least height on `key`'s tab: on the Mail tab, all the
  -- room under its window (Layout), so the text starts right under it.
  function Insp.Least(key)
    if key == "mail" and (S.mailText or 0) > SAY_MIN then return S.mailText end
    return SAY_MIN
  end

  -- The tab's own text, laid under its drawing -- or over the whole card,
  -- for a tab that draws nothing.
  function Insp.Idle(key)
    local idle, entry = S.idleBlock, S.idle[key]
    if not (idle and entry) then return end
    local h = Lay(idle, entry.title, entry.text, 0)
    if Ctx.Height(key) == 0 then
      idle.Rule:Hide()
      h = math.max(h, S.bodyH - 2)
    else
      idle.Rule:Show()
      local least = Insp.Least(key)
      if h < least then h = least end
    end
    idle:SetHeight(h)
  end

  function Insp.SetTab(key)
    S.shown = false
    Insp.Show(nil)
    Insp.Idle(key)
  end

  -- The same entry again, after its text or the tab's changed.
  function Insp.Repaint()
    local entry = S.shown
    S.shown = false
    Insp.Idle(S.tab)
    Insp.Show(entry or nil)
  end

  -- The height an entry's text needs, `extraH` included. Its tooltip's
  -- summary is cut here too, with the measuring, so no hover is the first
  -- to cut one. A row that greys says why in a text of its own (Rows.Why):
  -- each of its texts is measured, and the tallest is its need.
  function Insp.Need(entry, extraH)
    ns.Summary(entry.text)
    local h = Lay(S.measure, entry.title, entry.text, extraH)
    local plain, off, blocked = entry.onText, entry.offText, entry.blockText
    if plain and plain ~= entry.text then
      ns.Summary(plain)
      h = math.max(h, Lay(S.measure, entry.title, plain, extraH))
    end
    if off and off ~= entry.text then
      ns.Summary(off)
      h = math.max(h, Lay(S.measure, entry.title, off, extraH))
    end
    if blocked and blocked ~= entry.text then
      ns.Summary(blocked)
      h = math.max(h, Lay(S.measure, entry.title, blocked, extraH))
    end
    return h
  end

  -- The height a text of the secondary role takes across the text zone.
  function Insp.TextHeight(text)
    local d = S.measure.Text
    d:SetText(text or "")
    return math.ceil(d:GetStringHeight() or 0)
  end
end

-------------------------------------------------------------
-- The inspector's drawings (Ctx)
--
-- One per tab, built the first time its tab is shown and painted every
-- time it is: on the Mail tab the character groups tile and, under it, the
-- Mail window small, wearing the Mail tab's settings; the Send tab's
-- recipients tile; on the Window tab the same window over a bit of world,
-- at the player's opacity and border; the minimap icon large and at its
-- own size, wearing everything its settings put on it, and the answers of
-- each setting with choices while it is pointed at. Drawn here, from the
-- settings, by the windows' own painting rules (the style's shell, the
-- mail rows' rules), rather than borrowed from the windows they describe:
-- those windows' own frames are not the panel's to reach into.
-------------------------------------------------------------
do
  local CTX_TOP = 11
  -- Sample mail: Midnight's goods as the auction house trades them --
  -- reagents of both quality tiers, whose links carry the tier's mark, and
  -- a fish, which has none -- each named short, so the small rows show the
  -- name whole beside its mark (MW.BOX, MW.SAMPLES): Azeroot of the gold
  -- tier and of the silver, Bright Linen and Evercore of the gold, Mana
  -- Lily and Sanguithorn of the silver, and Lynxfish. The first sale is
  -- SAMPLE_SALE and the first win cost SAMPLE_PRICE, the gold coming with
  -- a coin for its icon.
  local SAMPLE_ITEMS = { 236775, 236774, 236965, 243582, 236778, 236770, 238366 }
  local SAMPLE_PRICE, SAMPLE_SALE = 522600, 13090000
  local SAMPLE_COIN = "Interface\\Icons\\INV_Misc_Coin_01"

  -- The height of each tab's drawing, and the gap under it.
  function Ctx.Height(key)
    -- The window takes the room between the tile and the text (Layout),
    -- under its caption (Ctx.PreviewRoom).
    if key == "mail" then return CTX_TOP + TILE_H + 8 + Ctx.PreviewRoom() + Ctx.MailMiniHeight() + 10 end
    if key == "send" then return CTX_TOP + TILE_H + 10 end
    if key == "window" then
      -- The drawing grows with the text size (Ctx.MiniHeight).
      return CTX_TOP + (S.installedHost and (HOST_H + 8) or 0) + Ctx.PreviewRoom() + Ctx.MiniHeight() + 10
    end
    if key == "minimap" then return CTX_TOP + 4 + Ctx.MinimapHeight() + 10 end
    return 0
  end

  -- Shows `key`'s drawing, building it the first time, and paints it.
  function Ctx.Show(key)
    for k, f in pairs(S.ctx) do
      if k ~= key and f:IsShown() then
        f:Hide()
        if f.Stop then f.Stop() end
      end
    end
    local f = S.ctx[key]
    local build = Ctx[key]
    if not f and type(build) == "function" and S.insp then
      f = build(S.insp)
      S.ctx[key] = f
    end
    if f then
      f:Show()
      if f.Paint then f.Paint() end
    end
  end

  -- Paints `key`'s drawing if it is the one on show.
  function Ctx.Paint(key)
    local f = S.ctx[key]
    if f and f:IsShown() and f.Paint then f.Paint() end
  end

  -- A setting that shows in the drawing changed.
  function Ctx.Repaint()
    Ctx.Paint(S.tab)
  end

  -- The mark for the way into arranging: the art the title bar wears for it
  -- (Theme.Glyph "layout"), else the grip it wore before that art. A white
  -- texture, or a frame of white dots, to tint and to anchor by its CENTER
  -- (a glyph's keyline overhangs it evenly); `w` is the mark's own width.
  function Ctx.Mark(parent, size, layer)
    local T = ns.Theme
    local glyph = T and type(T.Glyph) == "function" and T.Glyph(parent, "layout", size, layer or "ARTWORK") or nil
    if glyph then
      glyph.w = size
      return glyph
    end
    local AR = ns.Arrange
    if AR and type(AR.Grip) == "function" then
      local dot = size >= 14 and 3 or 2
      local grip = AR.Grip(parent, dot, 2)
      grip.w = 2 * dot + 2
      return grip
    end
    return nil
  end

  function Ctx.TintMark(mark, r, g, b, a)
    if not mark then return end
    local dots = mark.dots
    if dots then
      for i = 1, #dots do dots[i]:SetVertexColor(r, g, b, a or 1) end
    elseif mark.SetVertexColor then
      mark:SetVertexColor(r, g, b, a or 1)
    end
  end

  -- A right-pointing chevron: the theme's glyph for it, else two bars of
  -- the addon's white tile.
  local function Chevron(parent, anchor)
    local T = ns.Theme
    local glyph = T and type(T.Glyph) == "function" and T.Glyph(parent, "chevron", 14, "OVERLAY") or nil
    if glyph then
      glyph:SetPoint("CENTER", anchor, "RIGHT", -15, 0)
      return { glyph }
    end
    local bars = {}
    for i = 1, 2 do
      local bar = parent:CreateTexture(nil, "OVERLAY")
      bar:SetTexture(WHITE)
      bar:SetSize(7, 1.6)
      bar:SetRotation(i == 1 and -0.785 or 0.785)
      bar:SetPoint("CENTER", anchor, "RIGHT", -15, i == 1 and 2.2 or -2.2)
      bars[i] = bar
    end
    return bars
  end

  -- Chrome at rest, lit while pointed at.
  local function TintChevron(tile, hot)
    local T = ns.Theme
    local parts = tile.Chevron
    for i = 1, #parts do T.SetColor(parts[i], hot and "textPrimary" or "textDisabled") end
  end

  -- The pointer on a drawing: the inspector says what it is, the tooltip
  -- too. Shared by every tile and badge, so a hover builds nothing.
  local function SpotEnter(self)
    if Rows.Held(self, SpotEnter) then return end
    if self.Hover then
      self.Hover:Show()
      TintChevron(self, true)
    end
    Rows.Hover(self)
    Tip.Entry(self, self.entry)
  end

  local function SpotLeave(self)
    if self.Hover then
      self.Hover:Hide()
      TintChevron(self, false)
    end
    GameTooltip:Hide()
    if Rows.HeldLeave(self) then return end
    Rows.Unhover(self)
  end

  -- A tile: a list the player builds, which opens a window of its own. The
  -- art with the accent's glow behind it, the name, a line of fact, and a
  -- chevron that says it opens something. Tagged as a card, so every skin
  -- paints it as it paints the house's other cards; what must survive that
  -- lives on a holder of its own (ArtHolder).
  function Ctx.Tile(parent, art, title, entry, onClick)
    local T = ns.Theme
    local tile = CreateFrame("Button", nil, parent, "BackdropTemplate")
    tile:SetSize(CTX_W, TILE_H)
    T.ApplyCard(tile)
    local holder = ArtHolder(tile)

    local hover = holder:CreateTexture(nil, "BACKGROUND")
    hover:SetPoint("TOPLEFT", tile, "TOPLEFT", 1, -1)
    hover:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", -1, 1)
    T.FillChrome(hover, WASH_A)
    hover:Hide()

    local mark = holder:CreateTexture(nil, "ARTWORK")
    mark:SetSize(32, 32)
    mark:SetPoint("LEFT", tile, "LEFT", 8, 0)
    mark:SetTexture(art)
    local glow = holder:CreateTexture(nil, "ARTWORK", nil, -1)
    glow:SetSize(58, 58)
    glow:SetPoint("CENTER", mark, "CENTER", 0, 0)
    glow:SetTexture(GLOW_TGA)
    glow:SetBlendMode("ADD")
    glow:SetAlpha(0.30)

    local name = T.CreateText(holder, "label")
    if _G.GameFontNormal then name:SetFontObject(T.HostFont(_G.GameFontNormal)) end
    T.SetColor(name, "accent")
    name:SetPoint("BOTTOMLEFT", tile, "LEFT", 48, 1)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    local sub = T.CreateText(holder, "secondary")
    sub:SetPoint("TOPLEFT", tile, "LEFT", 48, -1)
    sub:SetJustifyH("LEFT")
    sub:SetWordWrap(false)

    tile.Chevron = Chevron(holder, tile)
    tile.Hover, tile.Glow, tile.Title, tile.Sub = hover, glow, name, sub
    S.tiles[#S.tiles + 1] = tile
    tile.titleText, tile.entry = title, entry
    TintChevron(tile, false)
    tile:SetScript("OnEnter", SpotEnter)
    tile:SetScript("OnLeave", SpotLeave)
    tile:SetScript("OnClick", onClick)
    return tile
  end

  function Ctx.PaintTile(tile, fact)
    local T = ns.Theme
    -- Their halo as their objects have it now (Theme section 3b).
    T.KeepHalo(tile.Title)
    T.KeepHalo(tile.Sub)
    tile.Glow:SetVertexColor(T.GetAccent())
    local room = CTX_W - 48 - 28
    T.FitText(tile.Title, room, tile.titleText, tile)
    T.FitText(tile.Sub, room, fact or "")
  end

  -- A window a tile opened: its tile says what it holds again once it
  -- closes, so a group made there is counted on the way back.
  local watched = setmetatable({}, { __mode = "k" })
  local function Watch(window, key)
    if not window or watched[window] or type(window.HookScript) ~= "function" then return end
    watched[window] = key
    window:HookScript("OnHide", function(self)
      if watched[self] == "send" then S.sendText = nil end
      -- The groups may have changed: the drawing's buttons are read again,
      -- and the panel laid out again for the rows of them it now has.
      if watched[self] == "mail" then
        S.gridStale = true
        if Panel.RefreshControls then Panel.RefreshControls() end
        return
      end
      local panel = S.frame
      if panel and panel:IsShown() then Ctx.Paint(watched[self]) end
    end)
  end

  function Ctx.OpenGroups()
    local groups = ns.CharacterGroups
    if groups and type(groups.OpenEditor) == "function" then
      Watch(groups.OpenEditor(nil, S.frame), "mail")
    end
  end

  function Ctx.OpenRecipients()
    local RM = ns.RecipientManager
    if RM and type(RM.Toggle) == "function" then
      RM.Toggle()
      Watch(RM._frame, "send")
    else
      ns.Print(L["RM_NOT_AVAILABLE"])
    end
  end

  -- A drawing's own inset ground and edge, from the palette (dark: black at
  -- 45% edged #2b2b2b; the light palette's own on a light one).
  local function PaintPlain(frame)
    local C = ns.Theme.Colors
    local f, e = C.inset, C.insetEdge
    frame:SetBackdropColor(f[1], f[2], f[3], f[4])
    frame:SetBackdropBorderColor(e[1], e[2], e[3], e[4])
  end
  Ctx.PaintPlain = PaintPlain

  -- A sample item's name, link and quality (`id`, one of SAMPLE_ITEMS).
  -- The first time one is not loaded yet, every one the client has not
  -- loaded is asked for, once; the drawing on show repaints once, when the
  -- last of them has arrived (the mail rows of the Mail tab's window and of
  -- the Window tab's name them). Until then a row's name is empty.
  local function SampleItem(id)
    local info = C_Item and C_Item.GetItemInfo
    local name, link, quality
    if type(info) == "function" then name, link, quality = info(id) end
    if not name and not S.sampleAsked then
      S.sampleAsked = true
      if type(info) == "function" and type(Item) == "table" and type(Item.CreateFromItemID) == "function" then
        -- One more than the items asked for, until all are asked: none
        -- can repaint the drawing from inside this paint.
        local waiting = 1
        local function Landed()
          waiting = waiting - 1
          if waiting > 0 then return end
          local f = S.ctx[S.tab]
          if f and f:IsVisible() and f.Paint then f.Paint() end
        end
        for i = 1, #SAMPLE_ITEMS do
          local each = SAMPLE_ITEMS[i]
          if not info(each) then
            local item = Item:CreateFromItemID(each)
            if item and item.ContinueOnItemLoad then
              waiting = waiting + 1
              item:ContinueOnItemLoad(Landed)
            end
          end
        end
        waiting = waiting - 1
      end
    end
    return name, link, quality
  end

  -- The Mail tab: the character groups tile, and under it the Mail window,
  -- small, wearing the Mail tab's settings (Ctx.Mini, the Mail tab's
  -- window), under its caption (Ctx.PreviewCaption), as tall as the room
  -- between the tile and the text (Layout).
  function Ctx.mail(card)
    local f = CreateFrame("Frame", nil, card)
    f:SetPoint("TOPLEFT", card, "TOPLEFT", CTX_X, -CTX_TOP)
    f:SetSize(CTX_W, TILE_H + 8 + Ctx.PreviewRoom() + Ctx.MailMiniHeight())
    local tile = Ctx.Tile(f, "Interface\\AddOns\\Postbox\\Media\\minimap-mailbag.tga",
      L["GROUPS_TITLE"], S.idle.mail, Ctx.OpenGroups)
    tile:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    local cap = Ctx.PreviewCaption(f)
    cap:SetPoint("TOPLEFT", tile, "BOTTOMLEFT", 0, -8)
    local sw = Ctx.Mini(f, true)
    sw:SetPoint("TOPLEFT", cap, "BOTTOMLEFT", 0, -Ctx.PREVIEW_GAP)
    S.mailMini = sw
    f.Paint = function()
      -- How many groups there are; none reads as the tile's way in. The
      -- words are made when the number changes.
      local CG = ns.CharacterGroups
      local list = CG and type(CG.List) == "function" and CG.List() or nil
      local n = type(list) == "table" and #list or 0
      if S.tileGroups ~= n or not S.tileFact then
        S.tileGroups = n
        S.tileFact = n > 0 and ns.Plural("OPT_GROUPS_COUNT", n) or L["GROUPS_NEW"]
      end
      Ctx.PaintTile(tile, S.tileFact)
      local h = Ctx.MailMiniHeight()
      f:SetHeight(TILE_H + 8 + Ctx.PaintPreviewCaption(cap) + h)
      Ctx.PaintMini(sw, h)
    end
    return f
  end

  -- The Send tab: the recipients tile. Its count walks every recipient
  -- Postbox knows, so it is counted only when this tab is shown, once each
  -- time the panel opens, and again after the manager closes.
  function Ctx.send(card)
    local f = CreateFrame("Frame", nil, card)
    f:SetPoint("TOPLEFT", card, "TOPLEFT", CTX_X, -CTX_TOP)
    f:SetSize(CTX_W, TILE_H)
    local tile = Ctx.Tile(f, "Interface\\AddOns\\Postbox\\Media\\minimap-bundleclean.tga",
      L["RM_OPT_BUTTON"], S.idle.send, Ctx.OpenRecipients)
    tile:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.Paint = function()
      if not S.sendText then
        local RM = ns.RecipientManager
        local count = (RM and type(RM.Count) == "function" and RM.Count()) or 0
        S.sendText = ns.Plural("RM_HERO_COUNT", count)
      end
      Ctx.PaintTile(tile, S.sendText)
    end
    return f
  end

  ---------------------------------------------------------
  -- The Mail window, small, over a bit of world
  --
  -- The Window tab's drawing: the Mail window as the look in force draws
  -- it, standing over a bit of world so its opacity shows, and nothing the
  -- window does not draw. Its frame: the fill at the player's opacity, the
  -- border, the corners and the sheen; under the Postbox style the title
  -- strip too, slim and without the title, since its colour and its fade
  -- are the settings' (a tint, the opacity, Light's shadow of the sheet).
  -- Inside: the Mail and Send tabs, two equal halves of the content's
  -- width, each caption centred, the Mail tab lit; three mail rows on the
  -- list's stripes -- the read dot, the sender in an auction outcome's tone
  -- or a character's class colour, the subject, the gold; the totals band;
  -- and the All mail button.
  --
  -- Every part is painted by the code that paints the window: the Postbox
  -- style's shell by its own painter (Skin.PaintShell: fill, strip,
  -- keyline, corners, sheen), its blocks from its palette, its tabs on the
  -- window tabs' tokens; a host UI's list, band and button by that UI's own
  -- skin pass, its edge by its own border (EllesmereUI) or its own template
  -- (ElvUI); the stripes, dots, senders and figures by the Mail tab's own
  -- rules (Theme.StyleMailRow, CollectTab.RowRules). Its text wears
  -- Postbox's fonts, so the face, the size and the outline show as they
  -- change.
  --
  -- In proportion to the real window, 480 units wide: its insets, gaps,
  -- strip and sheen scaled to the drawing's width. The text is at the size
  -- it is set, so a tab, a row, the band and the button are each as tall as
  -- their line needs and never less than their scaled height: the drawing
  -- grows with the text size (Ctx.Height measures it from the fonts), and
  -- no caption or sender in it is cut; only an item's name too long for the
  -- subject's room is shortened, as the list shortens it. Built once; a
  -- paint lays out again only when a height moved, and makes nothing.
  --
  -- One window, two drawings: the Window tab's, as above, and the Mail
  -- tab's, the same frame, tabs, list, band and button wearing the Mail
  -- tab's settings as well (below, "The Mail tab's window").
  ---------------------------------------------------------
  local MW = {
    -- The window stands this far in from the world's edges.
    PAD_X = 10, PAD_Y = 9,
    -- The real window's width, and the heights of its parts the drawing
    -- scales: the Postbox style's title strip and sheen (Skin_Postbox), a
    -- compact mail row and the All mail button (CollectTab).
    REAL_W = 480, STRIP = 25, SHEEN = 90, ROW = 26, BUTTON = 28,
    -- What a line of text is given over its font's height: on a tab or a
    -- button, and on a row or the band.
    CONTROL_AIR = 5, LINE_AIR = 4,
    -- A row: the read dot (the list's, RowRules.DOT less one) and where its
    -- centre stands, where the sender begins, the gap between two columns,
    -- and the room kept at the row's right end.
    DOT = 7, DOT_X = 6, SENDER_X = 13, COL_GAP = 5, ROW_END = 4,
    -- The band's text stands this far in from its ends.
    BAND_PAD = 4,
    -- The gold one of your characters sent, the third row's.
    GIFT = 2500000,
    -- The rows, top down: an auction sale and an auction win, unread, and
    -- gold from one of your characters, read. `kind` is the auction
    -- outcome (none: the character), `fig` the figure's place in the
    -- figures (MW.Figures), `tone` its colour, `item` the one it names
    -- (SAMPLE_ITEMS): Mana Lily, Azeroot, Evercore.
    SAMPLES = {
      { kind = "sold", read = false, fig = 1, tone = "positive", item = 236778 },
      { kind = "bought", read = false, fig = 2, tone = "negative", item = 236775 },
      { read = true, fig = 3, tone = "positive", item = 243582 },
    },
    -- The heights in force (MW.Heights), the tabs' columns
    -- (Theme.ColumnEdges), and the blocks stacked under the tabs with their
    -- heights (MW.Lay): filled in place.
    h = {}, cols = {}, ACROSS = {}, TALL = {},
  }

  -- The drawing's width over the real window's.
  function MW.K()
    return (CTX_W - 2 * MW.PAD_X) / MW.REAL_W
  end

  -- A length of the real window at the drawing's scale, at least one unit.
  function MW.Scaled(v)
    return math.max(1, math.floor(v * MW.K() + 0.5))
  end

  -- The Postbox style's own look, whose palette the drawing paints from (a
  -- creative style lays art of its own, and is drawn as a host's look is).
  function MW.Own()
    local skin = ns.Skin
    return (skin and skin.IsPostboxStyle and not skin.IsCreativeStyle and skin.Palette) and true or false
  end

  -- The height of a text role's line, from its font as it is now: the
  -- face and the text size move it.
  function MW.Line(role)
    local object = ns.Theme.FontObject(role)
    local size
    if object and type(object.GetFont) == "function" then
      local _, h = object:GetFont()
      size = tonumber(h)
    end
    return math.ceil(size or 12)
  end

  -- The caption over each drawing of the window, saying it is one, so no
  -- one takes it for the window and reaches for All mail: small and muted
  -- as the Minimap tab's captions are (Ctx.Caption), across the drawing,
  -- one line tall, PREVIEW_GAP over the drawing. Its room comes out of the
  -- Mail tab's window (Layout); the Window tab's text stands under it.
  Ctx.PREVIEW_GAP = 4
  function Ctx.PreviewRoom()
    return MW.Line("secondary") + Ctx.PREVIEW_GAP
  end

  function Ctx.PreviewCaption(parent)
    local cap = Ctx.Caption(parent)
    cap:SetWidth(CTX_W)
    if cap.SetMaxLines then cap:SetMaxLines(1) end
    cap:SetText(L["OPT_DRAWING_PREVIEW"])
    return cap
  end

  -- Its height, from the font as it is now; -> the room it takes.
  function Ctx.PaintPreviewCaption(cap)
    local line = MW.Line("secondary")
    if cap.lineH ~= line then
      cap.lineH = line
      cap:SetHeight(line)
    end
    return line + Ctx.PREVIEW_GAP
  end

  -- Every height of the drawing, into MW.h, from the fonts in force; ->
  -- the drawing's whole height. A host's button is the real one, in its own
  -- font (the tab role's); the strip is the Postbox style's alone.
  function MW.Heights()
    local h, TM, S_ = MW.h, ns.Theme.Metrics, MW.Scaled
    local own = MW.Own()
    local caption = MW.Line("bodySmall")
    local line = math.max(MW.Line("label"), MW.Line("value"), MW.Line("secondary"))
    h.strip = own and S_(MW.STRIP) or 0
    h.titleGap = S_(TM.inset)
    h.tab = math.max(S_(TM.tabHeight), caption + MW.CONTROL_AIR)
    h.underTabs = S_(TM.space.snug + TM.inset)
    h.pad = S_(TM.tightGap)
    h.row = math.max(S_(MW.ROW), line + MW.LINE_AIR)
    h.rowGap = 1
    h.gap = S_(TM.gap)
    h.band = math.max(S_(TM.controlHeight), MW.Line("value") + MW.LINE_AIR)
    h.button = math.max(S_(MW.BUTTON), (own and caption or MW.Line("tab")) + MW.CONTROL_AIR)
    h.bottom = S_(2 * TM.inset)
    h.side = S_(2 * TM.inset)
    h.list = 2 * h.pad + #MW.SAMPLES * h.row + (#MW.SAMPLES - 1) * h.rowGap
    h.win = h.strip + h.titleGap + h.tab + h.underTabs + h.list + h.gap + h.band + h.gap + h.button + h.bottom
    h.total = h.win + 2 * MW.PAD_Y
    return h.total
  end

  -- For Ctx.Height, which stands before this section.
  function Ctx.MiniHeight()
    return MW.Heights()
  end

  -- A caption on one of the drawing's controls, `width` wide (its tab or
  -- its button), in a box of its own: the control less 3 at each end, one
  -- line, centred. Every caption in every language fits its control at
  -- every text size; one that ever did not would be cut short by the house
  -- fitter rather than spill out of its control.
  function MW.Caption(fs, width, text)
    if not fs then return end
    if fs.SetMaxLines then fs:SetMaxLines(1) end
    ns.Theme.FitText(fs, width - 6, text)
  end

  -- Four lines of the addon's white tile round `frame`.
  function MW.Edges(frame, layer, sub)
    local e = {}
    for i = 1, 4 do e[i] = frame:CreateTexture(nil, layer, nil, sub) end
    return e
  end

  function MW.LayEdges(e, frame, w)
    for i = 1, 4 do e[i]:ClearAllPoints() end
    e[1]:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    e[1]:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    e[1]:SetHeight(w)
    e[2]:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    e[2]:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    e[2]:SetHeight(w)
    e[3]:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -w)
    e[3]:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, w)
    e[3]:SetWidth(w)
    e[4]:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -w)
    e[4]:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, w)
    e[4]:SetWidth(w)
  end

  -- A block of the Postbox style (the list, the band, the button): a fill
  -- and a one-unit edge, in the palette's colours for it at each paint.
  function MW.Block(parent)
    local b = CreateFrame("Frame", nil, parent)
    b.Fill = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.Fill:SetAllPoints()
    b.Edges = MW.Edges(b, "BORDER", 1)
    MW.LayEdges(b.Edges, b, 1)
    return b
  end

  function MW.PaintBlock(b, fill, edge)
    b.Fill:SetColorTexture(fill[1], fill[2], fill[3], fill[4] or 1)
    local e = b.Edges
    for i = 1, 4 do e[i]:SetColorTexture(edge[1], edge[2], edge[3], edge[4] or 1) end
  end

  -- The rows' figures, made once: the sale, the price, the gold sent.
  function MW.Figures()
    local fig = S.miniFigures
    if not fig then
      local F = ns.Core and ns.Core.Formatting
      local money = F and F.FormatMoneyCompact
      fig = { money and money(SAMPLE_SALE, true) or "1309g", money and money(SAMPLE_PRICE, true) or "52g",
        money and money(MW.GIFT, true) or "250g" }
      S.miniFigures = fig
    end
    return fig
  end

  -- The world: a ground and two soft patches of light, which the window
  -- lets through at its opacity. The world is drawn on a frame of its own
  -- inside the swatch, which clips it: the patches reach past its edge.
  function Ctx.Swatch(parent)
    local sw = CreateFrame("Frame", nil, parent)
    sw:SetSize(CTX_W, Ctx.MiniHeight())
    if sw.SetClipsChildren then sw:SetClipsChildren(true) end
    local world = CreateFrame("Frame", nil, sw)
    world:SetAllPoints(sw)
    local ground = world:CreateTexture(nil, "BACKGROUND", nil, -8)
    ground:SetAllPoints()
    ground:SetTexture(WHITE)
    if ground.SetGradient and type(CreateColor) == "function" then
      ground:SetGradient("VERTICAL", CreateColor(0.11, 0.16, 0.15, 1), CreateColor(0.18, 0.29, 0.27, 1))
    else
      ground:SetVertexColor(0.15, 0.22, 0.21, 1)
    end
    -- Two soft patches of light, green and earth, from the minimap's glow.
    for i = 1, 2 do
      local patch = world:CreateTexture(nil, "BACKGROUND", nil, -6)
      patch:SetTexture(GLOW_TGA)
      patch:SetBlendMode("ADD")
      if i == 1 then
        patch:SetVertexColor(0.37, 0.56, 0.49)
        patch:SetAlpha(0.9)
        patch:SetSize(160, 100)
        patch:SetPoint("CENTER", sw, "CENTER", -46, 14)
      else
        patch:SetVertexColor(0.54, 0.44, 0.25)
        patch:SetAlpha(0.8)
        patch:SetSize(180, 110)
        patch:SetPoint("CENTER", sw, "CENTER", 76, -30)
      end
    end
    local edge = CreateFrame("Frame", nil, sw, "BackdropTemplate")
    edge:SetAllPoints(sw)
    edge:SetFrameLevel(world:GetFrameLevel() + 1)
    edge:SetBackdrop({ edgeFile = WHITE, edgeSize = 1 })
    edge:SetBackdropBorderColor(0.17, 0.17, 0.17, 1)
    sw.World = world
    return sw
  end

  -- The drawing: the Window tab's, over its bit of world; or with `mail`
  -- the Mail tab's, across the inspector's whole width with no world round
  -- it -- its look's opacity is the Window tab's to show, and its rows need
  -- the room -- whose list, segments and category buttons are its own
  -- (MW.BuildMail).
  function Ctx.Mini(parent, mail)
    local T = ns.Theme
    local skin = ns.Skin
    local own = MW.Own()
    local sw
    if mail then
      sw = CreateFrame("Frame", nil, parent)
      sw:SetSize(CTX_W, 1)
      sw.World = sw
    else
      sw = Ctx.Swatch(parent)
    end
    local win = CreateFrame("Frame", nil, sw, (not own) and "BackdropTemplate" or nil)
    win:SetFrameLevel(sw.World:GetFrameLevel() + 2)
    local px, py = mail and 0 or MW.PAD_X, mail and 0 or MW.PAD_Y
    win:SetPoint("TOPLEFT", sw, "TOPLEFT", px, -py)
    win:SetPoint("BOTTOMRIGHT", sw, "BOTTOMRIGHT", -px, py)
    win.own, win.mail = own, mail and true or false
    if not own then
      -- A host's or Blizzard's window: its fill at the opacity and an edge
      -- standing for its frame (MW.PaintHost); under ElvUI, ElvUI's own
      -- template, which the real window wears.
      win.Fill = win:CreateTexture(nil, "BACKGROUND", nil, -8)
      win.Fill:SetAllPoints()
      win.Edges = MW.Edges(win, "BORDER", 6)
      if HostSkinName() == "ElvUI" and type(win.SetTemplate) == "function" then
        win.template = pcall(win.SetTemplate, win, "Transparent")
      end
    end

    -- The Mail tab and the Send tab: the window's own plates.
    win.Tabs = {}
    for i = 1, 2 do
      local plate = T.CreatePlate(win, "tab")
      plate:EnableMouse(false)
      if plate.Text then plate.Text:SetFontObject(T.FontObject("bodySmall")) end
      if skin and skin.StyleTabPlate then skin.StyleTabPlate(plate) end
      win.Tabs[i] = plate
    end

    -- The list and its rows. Each row is a frame of its own, so a host's
    -- repaint of the list (which fades the textures the list itself owns)
    -- leaves the rows' stripes and dots alone, as in the window.
    local list
    if own then
      list = MW.Block(win)
    else
      list = CreateFrame("Frame", nil, win, "BackdropTemplate")
      T.ApplyList(list)
    end
    list.Rows = {}
    for i = 1, mail and 0 or #MW.SAMPLES do
      local row = CreateFrame("Frame", nil, list)
      MW.Dot(row):SetPoint("CENTER", row, "LEFT", MW.DOT_X, 0)
      row.Sender = T.CreateText(row, "label")
      row.Sender:SetPoint("LEFT", row, "LEFT", MW.SENDER_X, 0)
      row.Subject = T.CreateText(row, "value")
      row.Subject:SetJustifyH("LEFT")
      row.Gold = T.CreateText(row, "secondary")
      row.Gold:SetPoint("RIGHT", row, "RIGHT", -MW.ROW_END, 0)
      for _, fs in ipairs({ row.Sender, row.Subject, row.Gold }) do
        fs:SetWordWrap(false)
        if fs.SetMaxLines then fs:SetMaxLines(1) end
      end
      list.Rows[i] = row
    end
    win.List = list

    -- The totals band.
    local band
    if own then
      band = MW.Block(win)
    else
      band = CreateFrame("Frame", nil, win, "BackdropTemplate")
      T.ApplyBand(band)
    end
    band.Text = T.CreateText(band, "value")
    band.Text:SetPoint("LEFT", band, "LEFT", MW.BAND_PAD, 0)
    band.Text:SetJustifyH("CENTER")
    band.Text:SetWordWrap(false)
    if band.Text.SetMaxLines then band.Text:SetMaxLines(1) end
    win.Band = band

    -- The All mail button: the Postbox style's block and caption, or under
    -- any other look the real button, which that look's skin paints.
    local button
    if own then
      button = MW.Block(win)
      button.Text = T.CreateText(button, "bodySmall")
      button.Text:SetPoint("CENTER", button, "CENTER", 0, 0)
    else
      button = T.CreateButton(nil, win)
      button:EnableMouse(false)
      button:SetText(L["CAT_ALL"])
    end
    win.Button = button
    if mail then MW.BuildMail(win) end

    -- A host's parts by its own pass, as the window's are.
    if not own and skin and type(skin.Refresh) == "function" then pcall(skin.Refresh, win) end
    sw.Mini = win
    return sw
  end

  -- The Mail and Send tabs, two equal halves of the content's width `inner`
  -- under the strip; -> where the content under them begins.
  function MW.LayTabs(win, inner)
    local h = MW.h
    local y = h.strip + h.titleGap
    local cols = ns.Theme.ColumnEdges(inner, 2, MW.Scaled(ns.Theme.Metrics.gap), MW.cols)
    for i = 1, 2 do
      local plate, col = win.Tabs[i], cols[i]
      plate:ClearAllPoints()
      plate:SetPoint("TOPLEFT", win, "TOPLEFT", h.side + col.left, -y)
      plate:SetSize(col.width, h.tab)
      plate.w = col.width
    end
    return y + h.tab + h.underTabs
  end

  -- Lays the drawing out at the heights in force, only where one moved.
  function MW.Lay(sw, win)
    local total = MW.Heights()
    local h = MW.h
    sw:SetHeight(total)
    local key = h.tab + 100 * h.row + 10000 * h.band + 1000000 * h.button
    if win.laid == key then return end
    win.laid = key
    local inner = CTX_W - 2 * MW.PAD_X - 2 * h.side
    local y = MW.LayTabs(win, inner)
    -- The list, the band and the button, one under the other, each across
    -- the content's width.
    MW.ACROSS[1], MW.ACROSS[2], MW.ACROSS[3] = win.List, win.Band, win.Button
    MW.TALL[1], MW.TALL[2], MW.TALL[3] = h.list, h.band, h.button
    for i = 1, 3 do
      local frame = MW.ACROSS[i]
      frame:ClearAllPoints()
      frame:SetPoint("TOPLEFT", win, "TOPLEFT", h.side, -y)
      frame:SetPoint("TOPRIGHT", win, "TOPRIGHT", -h.side, -y)
      frame:SetHeight(MW.TALL[i])
      y = y + MW.TALL[i] + h.gap
    end
    local rows = win.List.Rows
    for i = 1, #rows do
      local at = -(h.pad + (i - 1) * (h.row + h.rowGap))
      rows[i]:ClearAllPoints()
      rows[i]:SetPoint("TOPLEFT", win.List, "TOPLEFT", h.pad, at)
      rows[i]:SetPoint("TOPRIGHT", win.List, "TOPRIGHT", -h.pad, at)
      rows[i]:SetHeight(h.row)
    end
    win.inner = inner
  end

  -- The Postbox style's frame and blocks, from its palette.
  function MW.PaintOwn(win)
    local T = ns.Theme
    local skin = ns.Skin
    local P = skin.Palette
    if type(skin.PaintShell) == "function" then skin.PaintShell(win, MW.h.strip, MW.Scaled(MW.SHEEN)) end
    MW.PaintBlock(win.List, P.list, P.listEdge)
    MW.PaintBlock(win.Band, P.band, P.bandEdge)
    MW.PaintBlock(win.Button, P.button, P.buttonEdge)
    MW.Caption(win.Button.Text, win.inner, L["CAT_ALL"])
    if skin.ButtonTextRGB then T.SetTextRGB(win.Button.Text, skin.ButtonTextRGB()) end
  end

  -- Any other look's frame: its fill in the host's colour at its opacity,
  -- and its edge -- the host's own border where it draws one on any frame
  -- (EllesmereUI's, Skin.ApplyBorder), else a line standing for the frame.
  -- ElvUI's template paints itself.
  function MW.PaintHost(win)
    local T = ns.Theme
    local e = win.Edges
    if win.template then
      win.Fill:Hide()
      for i = 1, 4 do e[i]:Hide() end
      return
    end
    local skin = GetSkin()
    local alpha = 1
    if skin and type(skin.GetBgOpacity) == "function" then
      local ok, a = pcall(skin.GetBgOpacity)
      if ok and type(a) == "number" then alpha = math.max(0, math.min(1, a)) end
    end
    local r, g, b
    local base = ns.Skin and ns.Skin.GetHostBaseline
    if type(base) == "function" then
      local ok, br, bg, bb = pcall(base)
      if ok and type(br) == "number" then r, g, b = br, bg, bb end
    end
    if not r then
      local c = T.Colors.surface
      r, g, b = c[1], c[2], c[3]
    end
    win.Fill:SetColorTexture(r, g, b, alpha)
    win.Fill:Show()

    -- The edge: none; the host's own (EllesmereUI draws it on the frame);
    -- Match on EllesmereUI's api backend, whose edge is its shell's chrome,
    -- which only its shell draws: a one-unit line in its place; a skin with
    -- no border to choose (ElvUI without its template): its one-unit edge;
    -- a stock window: Blizzard's frame.
    local size, a = 0, 0
    local er, eg, eb = 1, 1, 1
    if skin then
      local style = type(skin.GetBorderStyle) == "function" and skin.GetBorderStyle() or "none"
      if type(skin.ApplyBorder) == "function" then
        pcall(skin.ApplyBorder, win)
        if style == "match" and type(skin.GetEdge) == "function" then
          local ok, _, _, _, _, px = pcall(skin.GetEdge)
          if ok and (tonumber(px) or 0) <= 0 then size, a = 1, 0.6 end
        end
      elseif style == "match" and type(skin.GetEdge) == "function" then
        local ok, cr, cg, cb, ca, px = pcall(skin.GetEdge)
        size, a = 1, 0.6
        if ok and type(px) == "number" and px > 0 then er, eg, eb, a = cr, cg, cb, ca end
      elseif style ~= "none" then
        local step = type(skin.GetBorderSize) == "function" and tonumber((skin.GetBorderSize())) or 1
        size = math.max(1, math.min(4, step or 1))
        a = (style == "light") and 0.35 or 0.75
      end
    elseif ns.Skin then
      size, a = 1, 0.6
    else
      size, a = 2, 0.45
    end
    if size > 0 and win.edgeW ~= size then
      win.edgeW = size
      MW.LayEdges(e, win, size)
    end
    for i = 1, 4 do
      e[i]:SetColorTexture(er, eg, eb, a)
      e[i]:SetShown(size > 0)
    end
  end

  -- The tabs: the Mail tab lit, its caption as the window writes it while
  -- mail waits (UI.TabCaption: its name and the dot where Tab indicator
  -- puts it, in the accent's mark tone); the Send tab idle.
  function MW.PaintTabs(win)
    local T = ns.Theme
    local UI = ns.MailboxUI
    local caption = L["TAB_COLLECT"]
    if UI and type(UI.TabCaption) == "function" and type(UI.GetTabIndicator) == "function" then
      local r, g, b = T.GetAccentTone("mark")
      local floor = math.floor
      caption = UI.TabCaption(UI.GetTabIndicator(),
        string.format("|cff%02x%02x%02x", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5)))
    end
    local tabs = win.Tabs
    MW.Caption(tabs[1].Text, tabs[1].w, caption)
    MW.Caption(tabs[2].Text, tabs[2].w, L["TAB_SEND"])
    for i = 1, 2 do T.SetPlateSelected(tabs[i], i == 1) end
  end

  -- An auction outcome where a row's sender stands, as the drawings say it:
  -- the auction house alone (PREVIEW_AH, as the list's rows abbreviate it),
  -- the outcome told only by the tone the list says it in (CollectTab's
  -- OutcomeSender, short), so the small rows keep room for the item's name.
  function MW.PaintOutcome(fs, kind)
    local R = ns.CollectTab and ns.CollectTab.RowRules
    fs:SetText(R and R.OutcomeSender and R.OutcomeSender(kind, nil, true) or "")
    if R and R.PaintSender then R.PaintSender(fs, nil) end
  end

  -- The rows, by the list's own rules: the stripe of the row's place, the
  -- read dot, the sender (an auction outcome in its tone; your character,
  -- in its class colour), the gold in its tone. The sender's column is as
  -- wide as the widest sender, so no sender is cut and the subjects start
  -- on one line; the subject has the rest, and a long one is shortened by
  -- the house fitter, as the list shortens it.
  function MW.PaintRows(win)
    local T = ns.Theme
    local R = ns.CollectTab and ns.CollectTab.RowRules
    local figs = MW.Figures()
    local rows = win.List.Rows
    local senderW, goldW = 0, 0
    for i = 1, #rows do
      local row, s = rows[i], MW.SAMPLES[i]
      T.StyleMailRow(row, i, false)
      if R and R.PaintDot then R.PaintDot(row.Indicator, s.read, false)
      else T.SetColor(row.Indicator, s.read and "read" or "unread") end
      local sender = row.Sender
      if s.kind then
        MW.PaintOutcome(sender, s.kind)
      else
        MW.PaintMe(sender)
      end
      row.Gold:SetText(T.Colorize(s.tone, figs[s.fig]))
      senderW = math.max(senderW, T.TextWidth(sender))
      goldW = math.max(goldW, T.TextWidth(row.Gold))
    end
    local x = MW.SENDER_X + math.ceil(senderW) + MW.COL_GAP
    local room = (win.inner or 0) - 2 * MW.h.pad - x - MW.COL_GAP - math.ceil(goldW) - MW.ROW_END
    for i = 1, #rows do
      local subject = rows[i].Subject
      if subject.x ~= x then
        subject.x = x
        subject:ClearAllPoints()
        subject:SetPoint("LEFT", rows[i], "LEFT", x, 0)
      end
      T.FitText(subject, math.max(1, room), SampleItem(MW.SAMPLES[i].item) or "")
    end
  end

  -- The third row's sender: you, in your class colour, as the list draws
  -- one of your characters (RowRules.PaintSender) -- your class read from
  -- the game where Postbox has not noted it yet.
  function MW.PaintMe(fs)
    local T = ns.Theme
    local R = ns.CollectTab and ns.CollectTab.RowRules
    -- Forever: the full name, shown as the player has chosen to see theirs.
    local H = ns.Helpers
    local name = H.PlayerName()
    fs:SetText(H.ShownName(name) or "")
    if R and R.PaintSender then R.PaintSender(fs, name) end
    if fs.__pbClass then return end
    local CS = ns.ContactService
    local token
    if type(UnitClass) == "function" then
      local _, t = UnitClass("player")
      token = t
    end
    local r, g, b
    if token and CS and type(CS.ClassColour) == "function" then r, g, b = CS.ClassColour(token) end
    if r then T.SetTextRGB(fs, r, g, b) end
  end

  -- The band's sums, as the window's band writes them (CollectTab's
  -- FitBanner): the two labels and the gold of each, in their tones on the
  -- band; where that is wider than the band, the two sums alone. The coins
  -- are inline textures, which a string's measure leaves out, so each is
  -- counted at its own size. `gained` and `paid`: the sums, in copper.
  function MW.PaintBand(win, gained, paid)
    local T = ns.Theme
    local F = ns.Core and ns.Core.Formatting
    local fs = win.Band.Text
    local room = (win.inner or 0) - 2 * MW.BAND_PAD
    if not (F and F.FormatMoneyIcons) then fs:SetText("") return end
    local up = "ff" .. (T.InkHex("positive", "band") or "40d55a")
    local down = "ff" .. (T.InkHex("negative", "band") or "ff4444")
    local earned = F.FormatMoneyIcons(gained, up, 1)
    local spent = F.FormatMoneyIcons(paid, down, 1)
    fs:SetWidth(room)
    fs:SetText(L["BANNER_EARNED_SHORT"] .. earned .. "   |   " .. L["BANNER_SPENT_SHORT"] .. spent)
    if T.TextWidth(fs) + 2 * (F.MONEY_ICON_SIZE or 12) > room then
      fs:SetText(earned .. "   |   " .. spent)
    end
  end

  -- `height`: the Mail tab's window's, which takes the room it is given.
  function Ctx.PaintMini(sw, height)
    local win = sw and sw.Mini
    if not win then return end
    if win.mail then return MW.PaintMail(sw, win, height) end
    MW.Lay(sw, win)
    if win.own then MW.PaintOwn(win) else MW.PaintHost(win) end
    MW.PaintTabs(win)
    MW.PaintRows(win)
    MW.PaintBand(win, SAMPLE_SALE + MW.GIFT, SAMPLE_PRICE)
  end

  ---------------------------------------------------------
  -- The Mail tab's window
  --
  -- The same window -- its frame, its tabs, its list, the band and All
  -- mail, painted as above -- wearing the Mail tab's settings as well, live:
  -- under the tabs the Inbox segment, and Done beside it while read mail has
  -- a tab of its own, each with its count while Show mail counts is on; the
  -- list, its rows one line or two (Larger mail rows), their gold and slots
  -- in columns or packed (Row layout), the stack count and the quality mark
  -- on the icons and the mark by the names where those settings put them;
  -- the read mail's divider, and the read mail under it, while read mail
  -- stays below the inbox (its fold as the window's divider was last left);
  -- and under the list, in the order the blocks are arranged in, the totals
  -- band (Show totals), All mail and the category buttons (Show category
  -- buttons): the window's own set in its arrangement, a character group's
  -- among them, each greyed where it would collect nothing.
  --
  -- The mail is a sample box (MW.BOX), always the same: auction outcomes in
  -- their tones, gold from you in your class colour, and the read letter
  -- from a friend in hers. Everything that counts counts the box -- the
  -- segments, the divider, the buttons, the band -- so a setting that hides
  -- a block moves no number, as in the window. Every part is painted by the
  -- rows' own rules (the dot, the stripe, the sender, the icon's edge, its
  -- count and mark, the name's mark and the money's tones); where each
  -- stands is the drawing's, in proportion, the columns in their default
  -- order without the time left, which leaves the names some room at a
  -- third of the window's width.
  --
  -- The window is as tall as the room between the tile and the text
  -- (Layout), whatever is switched on or off. The list is its one elastic
  -- part, as in the window: it shows the rows that fit, from the top, the
  -- last one cut by the list's foot, and while read mail is below the inbox
  -- and its divider's place is further down, the divider stands pinned at
  -- the list's foot, as the window's does. A paint makes nothing: what counts
  -- the box is written once, and again only when the buttons change.
  ---------------------------------------------------------

  -- The sample box, newest first. `kind`: the auction outcome (nil: a
  -- letter); `me`: from you; `money`: the gold it holds; `price`: what a won
  -- auction cost; `item`: what it sold or holds (SAMPLE_ITEMS), named by a
  -- sale as its mail is and drawn with its own icon and mark where it is
  -- held; `n`: the first stack, on the icon; `items`: the stacks it holds,
  -- `total` the item's count in all of them. One stack each: the count a
  -- second stack adds to a name leaves it no room on a won auction's row.
  -- The won auctions, whose row holds the price and the slots too, are the
  -- shortest names; the sales, which keep the room of a mark before the
  -- name, the next; the expired and canceled ones have the most room.
  MW.BOX = {
    { kind = "sold", money = SAMPLE_SALE, item = 243582 },                                  -- Evercore
    { kind = "bought", price = SAMPLE_PRICE, n = 20, items = 1, total = 20, item = 236775 }, -- Azeroot, gold
    { me = true, money = MW.GIFT, read = true, subject = "PREVIEW_GIFT" },
    { kind = "sold", money = 864000, item = 238366 },                                       -- Lynxfish
    { kind = "expired", n = 5, items = 1, total = 5, item = 236770 },                       -- Sanguithorn, silver
    { kind = "bought", price = 271300, n = 10, items = 1, total = 10, read = true, item = 238366 },
    { kind = "sold", money = 4120000, read = true, item = 236775 },
    { kind = "canceled", n = 12, items = 1, total = 12, item = 236965 },                    -- Bright Linen, gold
    { kind = "sold", money = 10500000, item = 243582 },
    { kind = "bought", price = 1564000, n = 20, items = 1, total = 20, item = 243582 },      -- Evercore, gold
    { kind = "sold", money = 640000, read = true, item = 236775 },
    { kind = "sold", money = 2210000, item = 238366 },
    { kind = "bought", price = 89900, n = 5, items = 1, total = 5, item = 236774 },         -- Azeroot, silver
    { kind = "sold", money = 1560000, read = true, item = 243582 },
  }
  -- Read, with nothing left in it: a letter from a friend whose class is
  -- known.
  MW.READ = { from = "Brynna", class = "DRUID", subject = "PREVIEW_LETTER", read = true, done = true }
  -- The arrangement the drawing's rows wear: every column it draws shown.
  MW.LAYOUT = { shown = { read = true, icon = true, sender = true, subject = true, money = true, slots = true } }
  -- The rows' icons: a coin for gold, a letter, the item's own.
  MW.COIN, MW.LETTER = SAMPLE_COIN, 134327
  -- A row: its icon's least size (one line) and that of a two-line row,
  -- where it stands, where the dot's centre stands, and the gap between a
  -- two-line row's lines; a category button's real height; a segment's
  -- caption room each side; the read mail's delete mark; the divider's
  -- fold mark; the outline's step out from what it rings.
  MW.ICON, MW.ICON_L, MW.ICON_X, MW.MDOT_X, MW.LINES_GAP = 14, 22, 10, 5, 2
  MW.SWEEP, MW.SEG_PAD, MW.DELETE, MW.FOLD, MW.RING = 26, 6, 9, 10, 2
  -- The category buttons, three to a row; the built-in ones in the
  -- window's order.
  MW.GRID_COLUMNS = 3
  MW.BUILTIN = { "bought", "sold", "canceled", "expired", "other", "alts" }
  -- The atlases the read mail's delete mark is drawn from.
  MW.DELETE_ART = { "uitools-icon-close", "transmog-icon-remove", "common-icon-redx" }

  -- The read mark: the list's flat round dot and its soft shadow.
  function MW.Dot(row)
    local dot = row:CreateTexture(nil, "ARTWORK")
    dot:SetTexture(WHITE)
    dot:SetSize(MW.DOT, MW.DOT)
    if type(row.CreateMaskTexture) == "function" then
      local mask = row:CreateMaskTexture()
      mask:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
      mask:SetAllPoints(dot)
      dot:AddMaskTexture(mask)
    end
    row.Indicator = dot
    local R = ns.CollectTab and ns.CollectTab.RowRules
    if R and R.ShadeDot then R.ShadeDot(row) end
    return dot
  end

  -- A text of one line, never wrapped.
  function MW.Text(parent, role, justify)
    local fs = ns.Theme.CreateText(parent, role)
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    if fs.SetMaxLines then fs:SetMaxLines(1) end
    return fs
  end

  -- `region` at `point` of `rel`, set again only when that moved.
  function MW.At(region, point, rel, x, y)
    if region.__mwP == point and region.__mwR == rel and region.__mwX == x and region.__mwY == y then return end
    region.__mwP, region.__mwR, region.__mwX, region.__mwY = point, rel, x, y
    region:ClearAllPoints()
    region:SetPoint(point, rel, point, x, y)
  end

  -- A mail row: the dot, the icon, the sender, the subject, the second line
  -- of a two-line row, the gold and the slots, and the delete mark the read
  -- mail carries.
  function MW.NewRow(parent)
    local T = ns.Theme
    local row = CreateFrame("Frame", nil, parent)
    MW.Dot(row):SetPoint("CENTER", row, "LEFT", MW.MDOT_X, 0)
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.Icon:SetPoint("LEFT", row, "LEFT", MW.ICON_X, 0)
    row.Sender = MW.Text(row, "label")
    row.Subject = MW.Text(row, "value")
    row.Detail = MW.Text(row, "secondary")
    row.Money = MW.Text(row, "secondary", "RIGHT")
    row.Slots = MW.Text(row, "secondary", "RIGHT")
    local art = T.FirstAtlas and T.FirstAtlas(MW.DELETE_ART)
    if art then
      row.Delete = row:CreateTexture(nil, "ARTWORK")
      row.Delete:SetAtlas(art, false)
      row.Delete:SetSize(MW.DELETE, MW.DELETE)
    else
      row.Delete = MW.Text(row, "value")
      row.Delete:SetText("\195\151")
    end
    T.SetColor(row.Delete, "textSecondary")
    row.Delete:SetPoint("RIGHT", row, "RIGHT", -MW.ROW_END, 0)
    row.Delete:Hide()
    row:Hide()
    return row
  end

  -- The read mail's divider: its ground and rule, the fold mark, its words,
  -- and Delete all at its right; once in the list, once pinned at its foot.
  function MW.NewDivider(parent)
    local T = ns.Theme
    local d = CreateFrame("Frame", nil, parent)
    d.Fill = d:CreateTexture(nil, "BACKGROUND")
    d.Fill:SetAllPoints()
    d.Rule = d:CreateTexture(nil, "ARTWORK")
    d.Rule:SetHeight(1)
    d.Rule:SetPoint("TOPLEFT", d, "TOPLEFT", 0, -1)
    d.Rule:SetPoint("TOPRIGHT", d, "TOPRIGHT", 0, -1)
    d.Rule:SetTexture(WHITE)
    d.Fold = d:CreateTexture(nil, "ARTWORK")
    d.Fold:SetSize(MW.FOLD, MW.FOLD)
    d.Fold:SetDesaturated(true)
    d.Fold:SetAlpha(0.7)
    d.Label = MW.Text(d, "secondary")
    d.Label:SetPoint("LEFT", d.Fold, "RIGHT", 4, 0)
    d.Delete = MW.Text(d, "secondary", "RIGHT")
    d.Delete:SetPoint("RIGHT", d, "RIGHT", -MW.ROW_END, 0)
    d:Hide()
    return d
  end

  -- A category button: the Postbox style's block and caption, or under any
  -- other look the real button, which that look's skin paints.
  function MW.NewSweep(win)
    local T = ns.Theme
    local button
    if win.own then
      button = MW.Block(win)
      button.Text = T.CreateText(button, "bodySmall")
      button.Text:SetPoint("CENTER", button, "CENTER", 0, 0)
    else
      button = T.CreateButton(nil, win)
      button:EnableMouse(false)
      button:SetText(" ")
      button.Text = button:GetFontString()
    end
    button:Hide()
    return button
  end

  -- The Mail tab's parts of the window: the segments, the rows and the
  -- dividers in a frame that ends where the list's padding begins (a row the
  -- list's foot cuts is cut there, as the window's scroll cuts it), the
  -- category buttons -- the built-in six now, a group's when it first
  -- appears (MW.Sweeps) -- and the outline.
  function MW.BuildMail(win)
    local T = ns.Theme
    win.Segs = {}
    for i = 1, 2 do
      local plate = T.CreatePlate(win, "segment")
      plate:EnableMouse(false)
      if plate.Text then plate.Text:SetFontObject(T.FontObject("bodySmall")) end
      win.Segs[i] = plate
    end
    local clip = CreateFrame("Frame", nil, win.List)
    if clip.SetClipsChildren then clip:SetClipsChildren(true) end
    win.Clip = clip
    win.Rows = {}
    for i = 1, #MW.BOX + 1 do win.Rows[i] = MW.NewRow(clip) end
    win.Divider, win.Pin = MW.NewDivider(clip), MW.NewDivider(clip)
    win.Grid = CreateFrame("Frame", nil, win)
    win.Sweeps, win.gridCols = {}, {}
    for i = 1, #MW.BUILTIN do win.Sweeps[MW.BUILTIN[i]] = MW.NewSweep(win) end
    local ring = CreateFrame("Frame", nil, win)
    ring:SetFrameLevel(win:GetFrameLevel() + 30)
    ring.Edges = MW.Edges(ring, "OVERLAY", 7)
    MW.LayEdges(ring.Edges, ring, 1)
    ring:Hide()
    win.Ring = ring
  end

  -- What the box counts, made once: the sums the band shows, what each
  -- built-in button would collect, and the texts that count it -- the
  -- segments' in each read-mail mode, Done's, All mail's and the
  -- divider's, with their numbers and without.
  function MW.Counts()
    local c = S.boxCounts
    if c then return c end
    c = { gained = 0, paid = 0, all = 0 }
    for i = 1, #MW.BOX do
      local m = MW.BOX[i]
      c.gained = c.gained + (m.money or 0)
      c.paid = c.paid + (m.price or 0)
      -- Every one of them is still to collect: no C.O.D. among them, and
      -- the read ones hold gold.
      c.all = c.all + 1
      local id = m.kind or (m.me and "alts") or "other"
      c[id] = (c[id] or 0) + 1
    end
    local n = #MW.BOX
    local inbox = L["VIEW_INBOX"]
    -- Inbox counts the whole box, the read mail under its divider with it,
    -- unless Done has the read mail.
    c.inbox = { fold = inbox .. " (" .. (n + 1) .. ")", tab = inbox .. " (" .. n .. ")", delete = inbox .. " (" .. n .. ")" }
    c.done = L["VIEW_DONE"] .. " (1)"
    c.allText = L["CAT_ALL"] .. " (" .. c.all .. ")"
    c.divider = L("INBOX_READ_DIVIDER", 1)
    S.boxCounts = c
    return c
  end

  -- The category buttons the window shows, in its order: the built-in six
  -- and a character group's with members, as the player arranged them
  -- (CollectTab.ReconcileGrid, the window's own rule), the hidden ones left
  -- out; each with its caption, with and without its count, and what it
  -- would collect of the box -- a group's, the mail its members sent. Read
  -- again when the panel opens and when the groups' window closes, and only
  -- then if the arrangement or the groups moved; nothing is made otherwise.
  function MW.Grid()
    local g = S.mailGrid
    if not g then
      g = { ids = {}, plain = {}, counted = {}, counts = {}, available = {}, n = 0 }
      S.mailGrid = g
    end
    local UI = ns.MailboxUI
    local CT = ns.CollectTab
    local CG = ns.CharacterGroups
    -- The arrangement as it is saved (MailboxUI.SetGridLayout): one string,
    -- read without making anything. Its table is asked for only when that
    -- or the groups moved.
    local Store = ns.Store
    local text = Store and type(Store.Get) == "function" and Store.Get("profile.gridLayout") or nil
    local list = CG and type(CG.List) == "function" and CG.List() or nil
    local groups = type(list) == "table" and #list or 0
    if g.built and not S.gridStale and g.text == text and g.list == list and g.groups == groups then return g end
    S.gridStale = false
    g.built, g.text, g.list, g.groups = true, text, list, groups
    local stored = UI and type(UI.GetGridLayout) == "function" and UI.GetGridLayout() or nil
    local c = MW.Counts()
    local available, labels = g.available, ns.CATEGORY_LABELS or {}
    for i = #available, 1, -1 do available[i] = nil end
    for i = 1, #MW.BUILTIN do available[i] = MW.BUILTIN[i] end
    -- A group's button counts the mail its members sent: here, yours.
    local me = ns.Helpers.PlayerName()
    local RC = ns.Recipients
    local key = me and RC and type(RC.Key) == "function" and RC.Key(me) or nil
    local names = {}
    for i = 1, groups do
      local group = list[i]
      if type(group) == "table" and type(group.members) == "table" and #group.members > 0 then
        local id = "group:" .. tostring(group.id)
        available[#available + 1] = id
        names[id] = CG.DisplayName and CG.DisplayName(group) or tostring(group.name or "")
        local set = CG.KeySet and CG.KeySet(group.id)
        c[id] = (key and type(set) == "table" and set[key]) and 1 or 0
      end
    end
    local entries
    if CT and type(CT.ReconcileGrid) == "function" then
      entries = CT.ReconcileGrid(stored, available, CG ~= nil, CG and CG.Exists or nil)
    end
    local n = 0
    for i = 1, #available do
      local entry = entries and entries[i]
      local id = entries and entry and entry.id or available[i]
      if not entries or (entry and entry.shown) then
        n = n + 1
        local label = names[id] or labels[id] or id
        local count = c[id] or 0
        g.ids[n], g.counts[n], g.plain[n] = id, count, label
        g.counted[n] = count > 0 and (label .. " (" .. count .. ")") or label
      end
    end
    for i = #g.ids, n + 1, -1 do g.ids[i], g.counts[i], g.plain[i], g.counted[i] = nil, nil, nil, nil end
    g.n = n
    return g
  end

  -- Rows of category buttons, `n` of them three to a row.
  function MW.GridRows(n)
    return math.ceil((n or 0) / MW.GRID_COLUMNS)
  end

  -- The Mail tab's window's heights beyond the window's own (MW.Heights),
  -- into MW.h: the segments and the gap under them; a one-line row as tall
  -- as its icon needs, a two-line row as its two lines; a category button,
  -- in its look's own font; the grid; and everything over the list.
  function MW.MailHeights()
    local h, TM, S_ = MW.h, ns.Theme.Metrics, MW.Scaled
    MW.Heights()
    local caption = MW.Line("bodySmall")
    local line = math.max(MW.Line("label"), MW.Line("value"))
    h.seg = math.max(S_(TM.segmentHeight), caption + MW.CONTROL_AIR)
    h.segGap = S_(TM.gap)
    h.iconC = math.max(MW.ICON, line + 2)
    h.rowC = math.max(h.row, h.iconC + 2)
    h.text2 = line + MW.LINES_GAP + MW.Line("secondary")
    h.iconL = math.max(MW.ICON_L, h.text2)
    h.rowL = math.max(S_(TM.rowHeight), h.iconL + 4)
    h.sweep = math.max(S_(MW.SWEEP), (MW.Own() and caption or MW.Line("tab")) + MW.CONTROL_AIR)
    local rows = MW.GridRows(MW.Grid().n)
    h.grid = rows > 0 and (rows * h.sweep + (rows - 1) * h.gap) or 0
    h.over = h.strip + h.titleGap + h.tab + h.underTabs + h.seg + h.segGap
  end

  -- The least the Mail tab's window can be: everything over the list, the
  -- list showing two two-line rows and the pinned divider, and every block
  -- under it shown. No world round it (Ctx.Mini).
  function MW.MailMin()
    local h = MW.h
    MW.MailHeights()
    local list = 2 * h.pad + 3 * h.rowL + 2 * h.rowGap
    local stack = h.band + h.gap + h.button + ((h.grid > 0) and (h.gap + h.grid) or 0)
    return h.over + list + h.gap + stack + h.bottom
  end

  -- For Ctx.Height and the tab's drawing: the height Layout gave the
  -- window, never less than its least.
  function Ctx.MailMiniHeight()
    local least = MW.MailMin()
    local given = S.mailMiniH or 0
    return given > least and given or least
  end

  -- What the Mail tab needs of the inspector: the tile, the caption, the
  -- window at its least and the text zone `textH` under it (Layout).
  function Ctx.MailNeed(textH)
    return CTX_TOP + TILE_H + 8 + Ctx.PreviewRoom() + MW.MailMin() + 10 + (textH or SAY_MIN)
  end

  -- The window's height in an inspector `bodyH` tall: all the room between
  -- the caption and the text zone.
  function Ctx.MailFill(bodyH, textH)
    S.mailMiniH = math.floor(bodyH - (CTX_TOP + TILE_H + 8) - Ctx.PreviewRoom() - 10 - (textH or SAY_MIN))
  end

  -- The settings the window shows, read once per paint.
  function MW.Read(st)
    local UI = ns.MailboxUI
    local get = UI and UI.GetOption
    st.compact = not get or get("compactRows") and true or false
    st.totals = not get or get("showTotals") and true or false
    st.grid = get and get("showCategoryButtons") and true or false
    st.counts = not get or get("showTabCounts") and true or false
    st.folded = get and get("readFolded") and true or false
    st.mode = UI and type(UI.GetReadMode) == "function" and UI.GetReadMode() or "fold"
    st.packed = UI and type(UI.GetRowPacking) == "function" and UI.GetRowPacking() == "packed" or false
    local order = UI and type(UI.GetStackOrder) == "function" and UI.GetStackOrder() or nil
    st.order = type(order) == "table" and order or MW.STACK
    return st
  end
  MW.STACK = { "band", "all", "grid" }
  MW.st = {}

  -- The segments, the list, and the blocks under it in their order, the
  -- window `height` tall; -> the list's inner height.
  function MW.MailLay(sw, win, height, st)
    local h = MW.h
    sw:SetHeight(height)
    local inner = CTX_W - 2 * h.side
    win.inner = inner
    local y = MW.LayTabs(win, inner)
    -- The segments: Inbox, and Done while read mail has a tab of its own,
    -- each as wide as the wider caption needs, from the left.
    local segs = win.Segs
    local two = st.mode == "tab"
    local c = MW.Counts()
    segs[1].caption = st.counts and c.inbox[st.mode] or L["VIEW_INBOX"]
    segs[2].caption = st.counts and c.done or L["VIEW_DONE"]
    local width, snug = 0, MW.Scaled(ns.Theme.Metrics.space.snug)
    for i = 1, two and 2 or 1 do
      local fs = segs[i].Text
      fs:SetText(segs[i].caption)
      width = math.max(width, TextW(fs))
    end
    width = math.min(width + 2 * MW.SEG_PAD, math.floor((inner - snug) / 2))
    for i = 1, 2 do
      local plate = segs[i]
      plate:SetShown(i == 1 or two)
      MW.At(plate, "TOPLEFT", win, h.side + (i - 1) * (width + snug), -y)
      plate:SetSize(width, h.seg)
      plate.w = width
    end
    y = y + h.seg + h.segGap
    -- The blocks under the list: All mail, and what each setting shows of
    -- the others.
    local showGrid = st.grid and h.grid > 0
    local stack = h.button
    if st.totals then stack = stack + h.gap + h.band end
    if showGrid then stack = stack + h.gap + h.grid end
    local listH = height - y - h.gap - stack - h.bottom
    local list = win.List
    MW.At(list, "TOPLEFT", win, h.side, -y)
    list:SetPoint("TOPRIGHT", win, "TOPRIGHT", -h.side, -y)
    list:SetHeight(listH)
    local clip = win.Clip
    clip:ClearAllPoints()
    clip:SetPoint("TOPLEFT", list, "TOPLEFT", h.pad, -h.pad)
    clip:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -h.pad, h.pad)
    y = y + listH + h.gap
    win.Band:SetShown(st.totals)
    win.Grid:SetShown(showGrid)
    local order = st.order
    for i = 1, #order do
      local id = order[i]
      local frame, tall = nil, 0
      if id == "band" and st.totals then
        frame, tall = win.Band, h.band
      elseif id == "all" then
        frame, tall = win.Button, h.button
      elseif id == "grid" and showGrid then
        frame, tall = win.Grid, h.grid
      end
      if frame then
        MW.At(frame, "TOPLEFT", win, h.side, -y)
        frame:SetPoint("TOPRIGHT", win, "TOPRIGHT", -h.side, -y)
        frame:SetHeight(tall)
        y = y + tall + h.gap
      end
    end
    win.rowW = inner - 2 * h.pad
    return listH - 2 * h.pad
  end

  -- A sender in a class's colour: a friend whose class is known.
  function MW.PaintClass(fs, token)
    local CS = ns.ContactService
    local r, g, b
    if token and CS and type(CS.ClassColour) == "function" then r, g, b = CS.ClassColour(token) end
    if r then ns.Theme.SetTextRGB(fs, r, g, b) end
  end

  -- A row's words and figures for mail `m`, by the rows' rules, and their
  -- widths, which the list's columns are measured from: the sender (an
  -- auction outcome in its tone, you or a friend in a class colour), the
  -- gold in its tone and the slots, briefly on a one-line row.
  function MW.RowTexts(row, m, two)
    local T = ns.Theme
    local R = ns.CollectTab and ns.CollectTab.RowRules
    local fs = row.Sender
    if m.kind then
      MW.PaintOutcome(fs, m.kind)
    elseif m.me then
      MW.PaintMe(fs)
    else
      fs:SetText(m.from)
      if R and R.PaintSender then R.PaintSender(fs, m.from) end
      MW.PaintClass(fs, m.class)
    end
    row.senderText, row.senderW = fs:GetText() or "", TextW(fs)
    local money, kind
    if R and R.MoneyText then money, kind = R.MoneyText(false, m.money or 0, 0, m.price, not two) end
    if money and R.MoneyShown and not R.MoneyShown(kind, MW.LAYOUT) then money = nil end
    local slots
    if (m.items or 0) > 0 then
      slots = T.Colorize("textSecondary", (R and R.SlotsText) and R.SlotsText(m.items, not two)
        or ns.Plural("COUNT_SLOTS", m.items))
    end
    row.moneyText, row.slotsText, row.moneyW, row.slotsW = money, slots, 0, 0
    if money then
      row.Money:SetText(money)
      row.moneyW = TextW(row.Money)
    end
    if slots then
      row.Slots:SetText(slots)
      row.slotsW = TextW(row.Slots)
    end
  end

  -- The `k`th mail's subject: its item's `name` with its count, as an
  -- auction's subject has it -- made when the name is first known, and
  -- kept, in one table made once.
  function MW.Subject(k, m, name)
    local t = S.boxSubjects
    if not t then
      t = { names = {} }
      S.boxSubjects = t
    end
    if t.names[k] ~= name then
      t.names[k] = name
      local total = m.total or 0
      -- No count before the name: the item is still loading.
      t[k] = (total > 1 and name ~= "") and (name .. " (" .. total .. ")") or name
    end
    return t[k]
  end

  -- An item's icon, by the client's own table, which needs nothing loaded.
  function MW.Icon(id)
    local icon = C_Item and type(C_Item.GetItemIconByID) == "function" and C_Item.GetItemIconByID(id) or nil
    return icon or 134400
  end

  -- Where a row stands and what it shows, by the list's columns in `fit`:
  -- the icon (the item's, a coin, a letter) with its count and its mark,
  -- the name's mark, the sender in its column, the subject in the room
  -- left; on a one-line row the gold and the slots each in its column
  -- (Columns) or closed up to the row's end (Packed), the subject running
  -- on through a column its mail leaves empty, as the window's rows do; on
  -- a two-line row the figures on the second line. `k`: its place in the
  -- list; `done`, the read mail, which carries the delete mark.
  function MW.PlaceRow(win, row, m, k, two, fit, done)
    local T = ns.Theme
    local R = ns.CollectTab and ns.CollectTab.RowRules
    local h = MW.h
    local rowH, size, gap = fit.rowH, two and h.iconL or h.iconC, MW.MGAP
    T.StyleMailRow(row, k, false)
    -- The read mail is told by its dot and its delete mark. The window
    -- also steps its row back with the row's alpha; the drawing does not:
    -- the options are read at full contrast, and faded, a friend's class
    -- color reads under 4.5:1 on the list.
    row:SetSize(win.rowW, rowH)
    MW.At(row, "TOPLEFT", win.Clip, 0, -(k - 1) * (rowH + h.rowGap))
    if R and R.PaintDot then R.PaintDot(row.Indicator, m.read, false)
    else T.SetColor(row.Indicator, m.read and "read" or "unread") end
    if row.iconSize ~= size then
      row.iconSize = size
      row.Icon:SetSize(size, size)
    end
    -- What it holds wears its own icon and mark; a sale, the coin, and
    -- names what it sold.
    local item = (m.items or 0) > 0
    local name, link
    if m.item then name, link = SampleItem(m.item) end
    row.Icon:SetTexture(item and MW.Icon(m.item) or (m.kind and MW.COIN) or MW.LETTER)
    local mark = item and R and R.QualityMark and R.QualityMark(link) or nil
    local subject
    if m.subject then
      subject = L[m.subject]
    else
      subject = MW.Subject(k, m, name or "")
      if item and m.items <= 1 and R and R.SaysCount and R.SaysCount(m.n, MW.LAYOUT) then
        subject = R.DropCount(subject, m.total)
      end
      if mark and R and R.MarkOnName and R.MarkOnName() then subject = R.WithMark(subject, mark) end
    end
    if R then
      if R.PaintQuality then R.PaintQuality(row, mark, MW.LAYOUT) end
      if R.PaintNameMark then R.PaintNameMark(row, mark, row, row.Subject) end
      if R.PaintCount then R.PaintCount(row, m.n or 0, m.items or 0, MW.LAYOUT) end
    end
    row.Delete:SetShown(done and true or false)
    local x0 = MW.ICON_X + size + gap
    local edge = MW.ROW_END + (done and (MW.DELETE + gap) or 0)
    local top = two and -math.floor((rowH - h.text2) / 2) or 0
    local money, slots = row.Money, row.Slots
    if two then
      money:Hide()
      slots:Hide()
      local a, b = row.moneyText, row.slotsText
      local line = (a and b) and (a .. MW.JOIN .. b) or a or b or ""
      MW.At(row.Detail, "BOTTOMLEFT", row, x0, -top)
      T.FitText(row.Detail, win.rowW - edge - x0, line)
      row.Detail:SetShown(line ~= "")
    else
      row.Detail:Hide()
      local off = MW.ROW_END
      if done then
        money:Hide()
        slots:Hide()
      elseif fit.packed then
        -- Each row its own: what it has, closed up to its end.
        if row.slotsText then
          MW.At(slots, "RIGHT", row, -off, 0)
          T.FitText(slots, row.slotsW, row.slotsText)
          off = off + row.slotsW + gap
        end
        if row.moneyText then
          MW.At(money, "RIGHT", row, -off, 0)
          T.FitText(money, row.moneyW, row.moneyText)
          off = off + row.moneyW + gap
        end
        edge = off
      else
        -- Every figure in its column; the subject runs on through the
        -- columns this mail leaves empty, up to the first it has.
        local slotsOff = off
        local moneyOff = off + ((fit.slotsW > 0) and (fit.slotsW + gap) or 0)
        if row.slotsText then
          MW.At(slots, "RIGHT", row, -slotsOff, 0)
          T.FitText(slots, fit.slotsW, row.slotsText)
          edge = slotsOff + fit.slotsW + gap
        end
        if row.moneyText then
          MW.At(money, "RIGHT", row, -moneyOff, 0)
          T.FitText(money, fit.moneyW, row.moneyText)
          edge = moneyOff + fit.moneyW + gap
        end
      end
      money:SetShown(row.moneyText ~= nil and not done)
      slots:SetShown(row.slotsText ~= nil and not done)
    end
    -- The sender in the sender's column (PaintList). One wider than it --
    -- yours, a friend's -- stands whole and this row's subject starts after
    -- it, the room coming from this row's subject alone, up to the
    -- column's own ceiling taken over this row's figures: MW.SUBJECT left
    -- before them, the mark before the name not counted, as in the column.
    local senderW = fit.senderW
    if row.senderW + 2 > senderW then
      local most = win.rowW - edge - x0 - gap - MW.SUBJECT
      senderW = math.max(senderW, math.min(row.senderW + 2, most))
    end
    local subX = x0 + senderW + gap + fit.markW
    MW.At(row.Sender, two and "TOPLEFT" or "LEFT", row, x0, top)
    T.FitText(row.Sender, senderW, row.senderText)
    MW.At(row.Subject, two and "TOPLEFT" or "LEFT", row, subX, top)
    -- Where the figures begin, and the subject's room, for the outlines.
    if not done and edge > fit.figures then fit.figures = edge end
    local run = math.max(1, win.rowW - edge - subX)
    row.run = run
    if R and R.FitSubject then
      R.FitSubject(row, row.Subject, run, subject, row)
    else
      T.FitText(row.Subject, run, subject)
    end
    row:Show()
  end
  -- The second line's figures, apart as the window's two-line row has them;
  -- the gap between a row's columns; the least room the subject keeps.
  MW.JOIN, MW.MGAP, MW.SUBJECT = "  |  ", 4, 16

  -- The read mail's divider at `k` in the list, or pinned at its foot: its
  -- ground and rule, the fold mark as the window's divider was left, its
  -- words with the count while Show mail counts is on, and Delete all.
  function MW.PaintDivider(win, d, st, rowH, k)
    local T = ns.Theme
    local h = MW.h
    d:SetSize(win.rowW, rowH)
    if k then
      MW.At(d, "TOPLEFT", win.Clip, 0, -(k - 1) * (rowH + h.rowGap))
    else
      MW.At(d, "BOTTOMLEFT", win.Clip, 0, 0)
    end
    d:SetFrameLevel(win.Clip:GetFrameLevel() + (k and 1 or 5))
    T.FillColor(d.Fill, "surface", 0.95)
    T.SetColor(d.Rule, "textSecondary")
    d.Rule:SetAlpha(0.25)
    d.Fold:SetTexture(st.folded and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
    local x = MW.Scaled(ns.Theme.Metrics.inset)
    MW.At(d.Fold, "LEFT", d, x, 0)
    local words = L["BTN_DELETE_ALL"]
    d.Delete:SetText(words)
    local del = TextW(d.Delete)
    T.FitText(d.Delete, del, words)
    T.SetColor(d.Delete, "textSecondary")
    T.SetColor(d.Label, "textSecondary")
    local room = win.rowW - x - MW.FOLD - 4 - del - MW.MGAP - MW.ROW_END
    T.FitText(d.Label, math.max(1, room), st.counts and MW.Counts().divider or L["INBOX_READ_DIVIDER_PLAIN"])
    d:Show()
  end

  -- The list: the rows that fit, from the top (the last cut by the list's
  -- foot), and while read mail stays below the inbox its divider and the
  -- read mail under it -- or, where the divider's place is below the rows
  -- that fit, the divider pinned at the list's foot, over them. The list's
  -- columns -- the sender's (its auctions'), the gold's, the slots' -- are
  -- as wide as the widest of the rows shown, as the window's are over its
  -- whole list.
  MW.fit = { markW = 0, senderW = 0 }
  function MW.PaintList(win, st, inner)
    local h = MW.h
    local fit = MW.fit
    local two = not st.compact
    local rowH = two and h.rowL or h.rowC
    local stride = rowH + h.rowGap
    local slots = math.ceil((inner + h.rowGap) / stride)
    local whole = math.floor((inner + h.rowGap) / stride)
    local n = #MW.BOX
    local fold = st.mode == "fold"
    local below = fold and (st.folded and 1 or 2) or 0
    local pinned = fold and n + below > whole
    local shown = math.min(n, slots)
    local letter = fold and not pinned and not st.folded
    local R = ns.CollectTab and ns.CollectTab.RowRules
    fit.markW = (R and R.NameMarkRoom) and R.NameMarkRoom() or 0
    fit.rowH, fit.packed, fit.figures = rowH, st.packed, 0
    -- The columns, from the rows drawn.
    local rows = win.Rows
    local senderW, auctionW, moneyW, slotsW = 0, 0, 0, 0
    for k = 1, shown + (letter and 1 or 0) do
      local row = (k <= shown) and rows[k] or rows[n + 1]
      local m = (k <= shown) and MW.BOX[k] or MW.READ
      MW.RowTexts(row, m, two)
      senderW = math.max(senderW, row.senderW)
      if m.kind then auctionW = math.max(auctionW, row.senderW) end
      if k <= shown then
        moneyW = math.max(moneyW, row.moneyW)
        slotsW = math.max(slotsW, row.slotsW)
      end
    end
    fit.moneyW, fit.slotsW = math.ceil(moneyW), math.ceil(slotsW)
    -- The sender's column is as wide as the widest auction's sender (every
    -- sender's, where no auction is in view), unless that leaves the
    -- subject less than MW.SUBJECT, the room for a letter or two and the
    -- cut: the senders -- the auction house in each outcome's tone, the
    -- class colours -- are what the drawing shows of a row, and the
    -- subject, a sample item's name, gives way to them first. A
    -- wider sender -- yours, a friend's -- takes its room from its own
    -- row's subject alone (PlaceRow). The mark before the name takes its
    -- room from the subject's, as in the window: the sender's column stays
    -- where it is.
    local line = win.rowW - MW.ICON_X - (two and h.iconL or h.iconC) - MW.MGAP - MW.ROW_END
    if not two then
      if fit.moneyW > 0 then line = line - fit.moneyW - MW.MGAP end
      if fit.slotsW > 0 then line = line - fit.slotsW - MW.MGAP end
    end
    if auctionW > 0 then senderW = auctionW end
    fit.senderW = math.max(1, math.min(math.ceil(senderW) + 2, line - MW.MGAP - MW.SUBJECT))
    for k = 1, n do
      if k <= shown then MW.PlaceRow(win, rows[k], MW.BOX[k], k, two, fit, false) else rows[k]:Hide() end
    end
    -- The last row the list shows whole, for the outlines.
    fit.last = math.min(shown, whole - (pinned and 1 or 0))
    if fold and not pinned then
      MW.PaintDivider(win, win.Divider, st, rowH, n + 1)
    else
      win.Divider:Hide()
    end
    if pinned then MW.PaintDivider(win, win.Pin, st, rowH, nil) else win.Pin:Hide() end
    if letter then MW.PlaceRow(win, rows[n + 1], MW.READ, n + 2, two, fit, true) else rows[n + 1]:Hide() end
    fit.letter = letter
  end

  -- A category button's caption colour under the Postbox style: the
  -- window's buttons' own, or the game's grey where it would collect
  -- nothing, made right for the button it stands on.
  function MW.ButtonRGB(off)
    local skin = ns.Skin
    if not off and skin and skin.ButtonTextRGB then return skin.ButtonTextRGB() end
    local base = _G.GameFontDisable
    local r, g, b = 0.5, 0.5, 0.5
    if base and type(base.GetTextColor) == "function" then
      local br, bg, bb = base:GetTextColor()
      if type(br) == "number" then r, g, b = br, bg, bb end
    end
    local T = ns.Theme
    if T.ButtonInk then return T.ButtonInk(r, g, b) end
    return r, g, b
  end

  -- The category buttons, three to a row across the grid, in the window's
  -- order, each greyed where it would collect nothing of the box.
  function MW.PaintGrid(win, st)
    local sweeps = win.Sweeps
    for _, b in pairs(sweeps) do b.used = false end
    if win.Grid:IsShown() then
      local T = ns.Theme
      local h = MW.h
      local g = MW.Grid()
      local P = win.own and ns.Skin and ns.Skin.Palette
      local cols = T.ColumnEdges(win.inner, MW.GRID_COLUMNS, h.gap, win.gridCols)
      for k = 1, g.n do
        local id = g.ids[k]
        local b = sweeps[id]
        if not b then
          b = MW.NewSweep(win)
          sweeps[id] = b
          local skin = ns.Skin
          if not win.own and skin and type(skin.Refresh) == "function" then pcall(skin.Refresh, win) end
        end
        local line = math.floor((k - 1) / MW.GRID_COLUMNS)
        local col = cols[k - line * MW.GRID_COLUMNS]
        MW.At(b, "TOPLEFT", win.Grid, col.left, -line * (h.sweep + h.gap))
        b:SetSize(col.width, h.sweep)
        local on = g.counts[k] > 0
        if P then
          MW.PaintBlock(b, P.button, P.buttonEdge)
          T.SetTextRGB(b.Text, MW.ButtonRGB(not on))
        else
          b:SetEnabled(on)
        end
        if b.Text then MW.Caption(b.Text, col.width, st.counts and g.counted[k] or g.plain[k]) end
        b.used = true
        b:Show()
      end
    end
    for _, b in pairs(sweeps) do
      if not b.used then b:Hide() end
    end
  end

  -- What the setting pointed at changes in the window, ringed in the
  -- accent: the Mail tab, the segments, the rows, the gold and slots'
  -- columns, the icons, the first item's icon or its name, the read mail
  -- (its divider and itself, or Done), the band or the buttons. Nothing
  -- where the setting changes nothing shown (Row layout on two-line rows,
  -- a block switched off). Pointed at from the rows (Pages.mail, `part`).
  MW.ringAt = {}
  function MW.RingTarget(win, part, st)
    local t = MW.ringAt
    local fit = MW.fit
    local rows = win.Rows
    local r = MW.RING
    t.a, t.b, t.ax, t.ay, t.bx, t.by, t.ap, t.bp = nil, nil, -r, r, r, -r, "TOPLEFT", "BOTTOMRIGHT"
    if part == "tab" then
      t.a, t.b = win.Tabs[1], win.Tabs[1]
    elseif part == "segs" then
      t.a, t.b = win.Segs[1], (st.mode == "tab") and win.Segs[2] or win.Segs[1]
    elseif part == "read" then
      if st.mode == "tab" then
        t.a, t.b = win.Segs[2], win.Segs[2]
      elseif st.mode == "fold" then
        local d = win.Divider:IsShown() and win.Divider or win.Pin
        t.a, t.b = d, fit.letter and rows[#MW.BOX + 1] or d
      end
    elseif part == "rows" then
      t.a, t.b = win.List, win.List
    elseif part == "figures" then
      if st.compact and (fit.last or 0) > 0 then
        t.a, t.b, t.ap, t.ax = rows[1], rows[fit.last], "TOPRIGHT", -(fit.figures - MW.MGAP) - r
        t.bx = -MW.ROW_END + r
      end
    elseif part == "icons" then
      if (fit.last or 0) > 0 then t.a, t.b = rows[1].Icon, rows[fit.last].Icon end
    elseif part == "mark" or part == "name" then
      -- The first mail holding the item: the box's second.
      local row = rows[2]
      if (fit.last or 0) >= 2 then
        if part == "mark" then
          t.a, t.b = row.Icon, row.Icon
        else
          -- The name and its marks: the mark before it, and the room it
          -- runs in, the mark after it at its end.
          t.a, t.b, t.ax, t.bp, t.bx = row.Subject, row.Subject, -fit.markW - r, "BOTTOMLEFT", (row.run or 0) + r
        end
      end
    elseif part == "band" then
      if win.Band:IsShown() then t.a, t.b = win.Band, win.Band end
    elseif part == "grid" then
      if win.Grid:IsShown() then t.a, t.b = win.Grid, win.Grid end
    end
    return t
  end

  function MW.PaintRing(win, st)
    local ring = win.Ring
    if not ring then return end
    local entry = S.shown
    local t = MW.RingTarget(win, entry and entry.part or nil, st or MW.st)
    if not t.a then
      ring:Hide()
      return
    end
    local r, g, b = ns.Theme.GetAccent()
    local e = ring.Edges
    for i = 1, 4 do e[i]:SetColorTexture(r, g, b, 0.9) end
    ring:ClearAllPoints()
    ring:SetPoint("TOPLEFT", t.a, t.ap, t.ax, t.ay)
    ring:SetPoint("BOTTOMRIGHT", t.b, t.bp, t.bx, t.by)
    ring:Show()
  end

  -- The Mail tab's window, `height` tall (never less than its least).
  function MW.PaintMail(sw, win, height)
    MW.MailHeights()
    local least = MW.MailMin()
    if not height or height < least then height = least end
    local st = MW.Read(MW.st)
    local inner = MW.MailLay(sw, win, height, st)
    if win.own then MW.PaintOwn(win) else MW.PaintHost(win) end
    MW.PaintTabs(win)
    local T = ns.Theme
    for i = 1, 2 do
      local plate = win.Segs[i]
      if plate:IsShown() then
        MW.Caption(plate.Text, plate.w, plate.caption)
        T.SetPlateSelected(plate, i == 1)
      end
    end
    MW.PaintList(win, st, inner)
    local c = MW.Counts()
    MW.PaintBand(win, c.gained, c.paid)
    local all = st.counts and c.allText or L["CAT_ALL"]
    local fs = win.Button.Text or win.Button:GetFontString()
    if fs then MW.Caption(fs, win.inner, all) end
    MW.PaintGrid(win, st)
    MW.PaintRing(win, st)
  end


  -- The accent row's reading, under its description: the ratios the tones
  -- read at, whether the guard moved them, and a semantic colour it sits
  -- close to. One text, measured once at its longest.
  local NEAR = { warning = "OPT_NEAR_WARNING", positive = "OPT_NEAR_POSITIVE", negative = "OPT_NEAR_NEGATIVE", info = "OPT_NEAR_INFO" }

  function Ctx.AccentReadout()
    local T = ns.Theme
    local text, mark, ink, moved = T.AccentReadout()
    local line = L("OPT_PB_READOUT", string.format("%.1f", text), string.format("%.1f", mark), string.format("%.1f", ink))
    if moved then line = line .. "\n" .. L["OPT_PB_LIFTED"] end
    local near = T.NearSemantic and T.NearSemantic()
    if near and NEAR[near] then line = line .. "\n" .. L("OPT_PB_NEAR", L[NEAR[near]]) end
    return line
  end

  -- The Window tab: who the look comes from, and the window itself.
  function Ctx.window(card)
    local T = ns.Theme
    local f = CreateFrame("Frame", nil, card)
    f:SetPoint("TOPLEFT", card, "TOPLEFT", CTX_X, -CTX_TOP)
    local y = 0
    local host
    if S.installedHost then
      -- The badge that used to hang on the Window heading: is this window
      -- wearing your UI's look, or Postbox's?
      host = CreateFrame("Frame", nil, f, "BackdropTemplate")
      host:SetBackdrop(PLAIN_BACKDROP)
      PaintPlain(host)
      host:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
      host:SetSize(CTX_W, HOST_H)
      host.Dot = host:CreateTexture(nil, "OVERLAY")
      host.Dot:SetSize(8, 8)
      host.Dot:SetPoint("LEFT", host, "LEFT", 10, 0)
      host.Text = T.CreateText(host, "secondary")
      host.Text:SetPoint("LEFT", host.Dot, "RIGHT", 8, 0)
      host.Text:SetJustifyH("LEFT")
      host.Text:SetWordWrap(false)
      host.entry = S.idle.window
      -- Motion only: a click passes on, so the panel still drags from here.
      host:EnableMouse(true)
      if host.SetPropagateMouseClicks then host:SetPropagateMouseClicks(true) end
      host:SetScript("OnEnter", SpotEnter)
      host:SetScript("OnLeave", SpotLeave)
      y = HOST_H + 8
    end
    -- The drawing under its caption (Ctx.PreviewCaption).
    local cap = Ctx.PreviewCaption(f)
    cap:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y)
    local sw = Ctx.Mini(f)
    sw:SetPoint("TOPLEFT", cap, "BOTTOMLEFT", 0, -Ctx.PREVIEW_GAP)
    f:SetSize(CTX_W, y + Ctx.PreviewRoom() + Ctx.MiniHeight())
    f.Paint = function()
      if host then
        PaintPlain(host)
        if S.badgeGreen then
          host.Dot:SetColorTexture(0.38, 0.80, 0.44, 1)
        else
          -- Neutral grey, not a warning colour: a deliberate choice is not
          -- a fault.
          host.Dot:SetColorTexture(0.54, 0.54, 0.58, 1)
        end
        T.FitText(host.Text, CTX_W - 36, S.idle.window.title, host)
      end
      local room = Ctx.PaintPreviewCaption(cap)
      Ctx.PaintMini(sw)
      f:SetHeight(y + room + MW.h.total)
    end
    return f
  end

  ---------------------------------------------------------
  -- The minimap icon as the map shows it
  --
  -- On a quiet ground roughly a minimap's own average value, so both glow
  -- and shadow read the way they will in the world. At rest, and while the
  -- pointer is on a setting with no drawing of its own: the icon as set,
  -- large enough to judge (G.BIG, 48), and beside it a copy at its own size (Icon
  -- size, or EllesmereUI's button under their minimap: MinimapButton's
  -- GetDrawnSize), captioned Actual size. Both WEAR the live settings: icon
  -- style, glow in Glow color (with its pulse), shadow, a sample number
  -- while Count on icon is on, and while Show marker is not Off the marker,
  -- in its shape and colour, at its anchor and offset (the Offset rows,
  -- which have no answers of their own, are seen here as they move). Faded,
  -- and still, while the icon is off.
  --
  -- A setting with choices answers with its choices while it is pointed at
  -- (Ctx.MinimapMode; its text then stands under the drawing, Layout), each
  -- the icon as set with that one setting changed, at G.CHOICE, side by side
  -- under their names, the current one marked as the arrange inspector marks
  -- a chosen segment, its words bright and the accent under them: Show
  -- marker (the plain icon, the icon with the marker, the marker alone as
  -- Always draws it while the icon is down), Shape (its six shapes, two
  -- rows of three), Color (its six colours on the shape chosen, two rows of
  -- three), Larger when alone, and Glow color (its five colours, three over
  -- two; Custom's, in either, the colour picked, or, with none yet, the
  -- colour the picker opens on). Anchor answers with the icon at G.ANCHOR
  -- in a three by three grid, the marker at each of its nine spots, the
  -- centre in the middle, each row's names under it. When to show answers with
  -- a grid: a column for each choice, a strip of ground for each situation
  -- that tells them apart -- no mail anywhere, mail on another character,
  -- new mail here -- and in each cell what the map shows then: nothing, the
  -- icon resting in gray, or the icon lit. Every marker is the map's own
  -- (MinimapButton.PaintMark) and so is the count (PaintCount): the same
  -- shapes and sizes, in whole screen pixels, on the same art's box. A
  -- figure whose marker reaches past its top or its foot (half off the
  -- art's top or bottom edge, on a style whose art comes near the square's;
  -- a Triangle at the top or the bottom) stands with the two centred as one
  -- (MinimapButton.MarkSpill).
  --
  -- Built once: a paint sets what shows, its size and its colours, and
  -- makes nothing. The pulses play only while the drawing is shown
  -- (f.Stop, Ctx.Show, the panel's hide).
  ---------------------------------------------------------
  -- The drawing's sizes: the icon as set (and its copy at its own size
  -- beside it, `at` as a share of the ground's width); the choices; the
  -- grid's icons; Anchor's icons and their strips.
  local G = { BIG = 48, CHOICE = 36, CELL = 20, AT_BIG = 0.37, AT_ACTUAL = 0.81, ANCHOR = 24, ANCHOR_STRIP = 42,
    -- The ground to the captions; the chosen caption's underline, and its
    -- gap.
    CAP_GAP = 5, MARK_GAP = 2, MARK_H = 2,
    -- The grid: a situation's name, the gap under it, its strip of ground,
    -- the gap to the next; and the gap between two rows of choices.
    LABEL_GAP = 2, STRIP_H = 30, STRIP_GAP = 4, ROW_GAP = 6 }
  -- The number the icon wears here while Count on icon is on.
  local MM = { COUNT = { me = 3, all = 12 } }
  -- Each answer's choices, in MinimapButton's order, and their names.
  -- Anchor's in reading order, as its grid stands.
  MM.IDS = {
    show = { "new", "any", "always" },
    expiry = { "off", "icon", "always" },
    marker = { "dot", "ring", "square", "bar", "exclamation", "triangle" },
    corner = { "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" },
    color = { "red", "gold", "accent", "class", "white", "custom" },
    glow = { "gold", "accent", "class", "white", "custom" },
    large = { "off", "on" },
  }
  MM.CAPS = {
    show = { "OPT_MINIMAP_SHOW_NEW", "OPT_MINIMAP_SHOW_ANY", "OPT_MINIMAP_SHOW_ALWAYS" },
    expiry = { "OPT_MINIMAP_EXPIRY_OFF", "OPT_MINIMAP_EXPIRY_ICON", "OPT_MINIMAP_EXPIRY_ALWAYS" },
    marker = { "OPT_MINIMAP_MARKER_DOT", "OPT_MINIMAP_MARKER_RING", "OPT_MINIMAP_MARKER_SQUARE",
      "OPT_MINIMAP_MARKER_BAR", "OPT_MINIMAP_MARKER_EXCLAMATION", "OPT_MINIMAP_MARKER_TRIANGLE" },
    corner = { "OPT_MINIMAP_ANCHOR_TL", "OPT_MINIMAP_ANCHOR_T", "OPT_MINIMAP_ANCHOR_TR", "OPT_MINIMAP_ANCHOR_L",
      "OPT_MINIMAP_ANCHOR_C", "OPT_MINIMAP_ANCHOR_R", "OPT_MINIMAP_ANCHOR_BL", "OPT_MINIMAP_ANCHOR_B",
      "OPT_MINIMAP_ANCHOR_BR" },
    color = { "OPT_MINIMAP_MARKERCOLOR_RED", "OPT_MINIMAP_GLOWCOLOR_GOLD", "OPT_MINIMAP_GLOWCOLOR_ACCENT",
      "OPT_COLOR_CLASS", "OPT_MINIMAP_GLOWCOLOR_WHITE", "OPT_MINIMAP_GLOWCOLOR_CUSTOM" },
    glow = { "OPT_MINIMAP_GLOWCOLOR_GOLD", "OPT_MINIMAP_GLOWCOLOR_ACCENT", "OPT_COLOR_CLASS",
      "OPT_MINIMAP_GLOWCOLOR_WHITE", "OPT_MINIMAP_GLOWCOLOR_CUSTOM" },
    large = { "OPT_MINIMAP_LARGE_OFF", "OPT_MINIMAP_LARGE_ON" },
    set = { "OPT_MINIMAP_PREVIEW_ACTUAL" },
  }
  -- The grid's situations, top down.
  MM.ROWS = { "OPT_MINIMAP_GRID_NONE", "OPT_MINIMAP_GRID_OTHER", "OPT_MINIMAP_GRID_HERE" }
  -- Each answer's current choice.
  MM.GET = { show = "GetShowWhen", expiry = "GetExpiry", marker = "GetMarker", corner = "GetMarkerCorner",
    color = "GetMarkerColor", glow = "GetGlowColor", large = "GetMarkerLarge" }
  -- The answers drawn in two rows (three, or as many as are offered, over
  -- the rest), and Custom's: offered only where the client has the colour
  -- picker (S.mmGlowCustom), and drawn only where it is offered.
  MM.ROWS2 = { marker = true, color = true, glow = true }
  MM.PICKED = { color = true, glow = true }
  -- Anchor's grid: each row's choices, by their place in MM.IDS.corner,
  -- and the column each stands in.
  MM.GRID = { { 1, 2, 3 }, { 4, 5, 6 }, { 7, 8, 9 } }

  -- A caption under a figure: centred, two lines at most.
  function Ctx.Caption(parent)
    local cap = ns.Theme.CreateText(parent, "secondary")
    cap:SetJustifyH("CENTER")
    if cap.SetJustifyV then cap:SetJustifyV("TOP") end
    cap:SetWordWrap(true)
    if cap.SetMaxLines then cap:SetMaxLines(2) end
    if cap.SetSpacing then cap:SetSpacing(2) end
    return cap
  end

  -- A caption's width: a third of the ground, every drawing alike.
  function Ctx.MinimapColumn()
    return math.floor(CTX_W / 3) - 4
  end

  -- The room under the ground: the gap, the captions, their underline.
  function Ctx.MinimapCaptionRoom()
    return G.CAP_GAP + (S.mmCapH or 12) + G.MARK_GAP + G.MARK_H
  end

  -- The grid's height: three situations, each its name and its strip.
  local function GridHeight()
    return 3 * ((S.mmLabelH or 12) + G.LABEL_GAP + G.STRIP_H) + 2 * G.STRIP_GAP
  end

  -- The ground's height: what the large icon needs, or the grid, if that
  -- needs more (a situation's name on two lines).
  function Ctx.MinimapStage()
    return math.max(STAGE, GridHeight())
  end

  -- Anchor's grid: three strips, each with its names under it.
  function Ctx.MinimapAnchorHeight()
    return 3 * (G.ANCHOR_STRIP + Ctx.MinimapCaptionRoom()) + 2 * G.ROW_GAP
  end

  -- The drawing's height under its top gap: the ground and its captions,
  -- or Anchor's grid, which needs more.
  function Ctx.MinimapHeight()
    return math.max(Ctx.MinimapStage() + Ctx.MinimapCaptionRoom(), Ctx.MinimapAnchorHeight())
  end

  -- The captions' height, the tallest any of them takes at its width, and
  -- the situations' names' across the ground, in the font as it is now --
  -- one line in English, two where a translation needs them. Run where
  -- Layout measures every text.
  function Ctx.MeasureCaptions()
    local cap = S.measure and S.measure.Cap
    if not cap then return end
    local h = 0
    cap:SetWidth(Ctx.MinimapColumn())
    for _, keys in pairs(MM.CAPS) do
      for i = 1, #keys do
        cap:SetText(L[keys[i]])
        local th = math.ceil(cap:GetStringHeight() or 0)
        if th > h then h = th end
      end
    end
    S.mmCapH = h
    h = 0
    cap:SetWidth(CTX_W)
    for i = 1, #MM.ROWS do
      cap:SetText(L[MM.ROWS[i]])
      local th = math.ceil(cap:GetStringHeight() or 0)
      if th > h then h = th end
    end
    S.mmLabelH = h
  end

  -- What the stage draws: the answers of the setting pointed at, where it
  -- has them (S.mmModes, Pages.minimap), else the icon as set.
  function Ctx.MinimapMode()
    local shown = S.shown
    return shown and S.mmModes and S.mmModes[shown] or "set"
  end

  -- The inspector moved to another setting (Insp.Show): the stage follows
  -- where that changes what it draws.
  function Ctx.Follow()
    local f = S.ctx.minimap
    if f and f.mode and f.mode ~= Ctx.MinimapMode() and f:IsVisible() then f.Paint() end
    -- The Mail tab's window rings what the setting pointed at changes.
    local sw = S.mailMini
    if sw and sw:IsVisible() then MW.PaintRing(sw.Mini) end
  end

  -- One figure: the shadow, the glow and its pulse, the icon; the count and
  -- the marker go on the figure itself (PaintCount, PaintMark).
  local function Figure(parent)
    local fig = CreateFrame("Frame", nil, parent)
    fig:SetSize(1, 1)
    local shadow = fig:CreateTexture(nil, "BACKGROUND", nil, -1)
    shadow:SetPoint("CENTER", fig, "CENTER", 0, -1)
    shadow:SetTexture(GLOW_TGA)
    shadow:SetVertexColor(0, 0, 0)
    shadow:SetAlpha(0.9)
    local glow = fig:CreateTexture(nil, "BACKGROUND", nil, 0)
    glow:SetPoint("CENTER", fig, "CENTER", 0, 0)
    glow:SetTexture(GLOW_TGA)
    glow:SetBlendMode("ADD")
    local pulse = glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.55)
    fade:SetDuration(1.6)
    fade:SetSmoothing("IN_OUT")
    local icon = fig:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER", fig, "CENTER", 0, 0)
    fig.Shadow, fig.Glow, fig.Pulse, fig.Icon = shadow, glow, pulse, icon
    fig:Hide()
    return fig
  end

  -- What a figure wears, filled in place before each figure is painted: the
  -- art, the switch, glow, pulse and shadow, the glow's colour, the marker
  -- (on the icon or not, its shape, colour, anchor and offset, larger when
  -- alone or not) and the count.
  local FIG = { spec = false, on = false, glowOn = false, pulseOn = false,
    shadowOn = false, gr = 1, gg = 1, gb = 1, mark = false, shape = "dot", corner = "TOPRIGHT", large = false,
    ox = 0, oy = 0, color = "red", count = 0 }

  -- `look`: "lit" (new mail: full colour, the glow), "rest" (nothing new:
  -- gray, a step back, no glow) or "alone" (the marker in its place, the
  -- icon's art hidden). The icon's own parts as MinimapButton draws them
  -- (ApplyLook): glow 2.2 times the icon, shadow 1.8 and a unit down. `y`,
  -- the figure's middle above the strip's (0 unless given).
  local function PaintFigure(fig, Icon, look, size, x, y)
    local P = FIG
    local spec, icon, glow, pulse = P.spec, fig.Icon, fig.Glow, fig.Pulse
    local rest, alone = look == "rest", look == "alone"
    local large = alone and P.large
    -- A marker that reaches past the icon's top or foot: the two centred
    -- as one. Both by the art's box (`spec.box`), as on the map.
    local spill = 0
    if (alone or P.mark) and Icon.MarkSpill then
      spill = Icon.MarkSpill(P.shape, P.corner, size, ns.Theme.OnePixel(fig), large, spec)
    end
    fig:ClearAllPoints()
    fig:SetPoint("CENTER", fig:GetParent(), "LEFT", x, (y or 0) - spill / 2)
    fig:SetSize(size, size)
    if spec.atlas then icon:SetAtlas(spec.atlas) else icon:SetTexture(spec.texture) end
    icon:SetSize(size, size * (spec.aspect or 1))
    icon:SetVertexColor(1, 1, 1)
    icon:SetDesaturated(rest or not P.on)
    icon:SetAlpha(rest and (Icon.REST_ALPHA or 0.65) or 1)
    icon:SetShown(not alone)
    fig.Shadow:SetSize(size * 1.8, size * 1.8)
    fig.Shadow:SetShown(P.shadowOn and not alone)
    glow:SetSize(size * 2.2, size * 2.2)
    if P.glowOn and not (rest or alone) then
      glow:SetVertexColor(P.gr, P.gg, P.gb)
      glow:Show()
      -- A switched-off icon does not keep moving.
      if P.on and P.pulseOn then
        if not pulse:IsPlaying() then pulse:Play() end
      else
        pulse:Stop()
      end
    else
      pulse:Stop()
      glow:Hide()
    end
    if Icon.PaintCount then Icon.PaintCount(fig, icon, size, (not alone) and P.count or 0) end
    if Icon.PaintMark then
      Icon.PaintMark(fig, icon, size, alone or P.mark, P.shape, P.corner, large, P.ox, P.oy, P.color, spec.box)
    end
    fig.used = true
    fig:Show()
  end

  local function HideFigure(fig)
    fig.Pulse:Stop()
    fig:Hide()
  end

  -- What the grid shows for situation `row` (1 no mail anywhere, 2 mail on
  -- another character, 3 new mail here) under When to show `id`: nil for
  -- nothing, else the look -- MinimapButton's own rule (Evaluate).
  local function GridLook(row, id)
    if row == 3 then return "lit" end
    if id == "always" or (row == 2 and id == "any") then return "rest" end
    return nil
  end

  -- A strip of ground, clipped, with three figures on it.
  local function Strip(parent)
    local strip = CreateFrame("Frame", nil, parent)
    strip:SetWidth(CTX_W)
    -- Clipped, with its art on a holder inside it: the glow reaches past
    -- the strip's edge.
    if strip.SetClipsChildren then strip:SetClipsChildren(true) end
    local art = ArtHolder(strip)
    local ground = art:CreateTexture(nil, "BACKGROUND", nil, -7)
    ground:SetAllPoints()
    ground:SetColorTexture(0.40, 0.41, 0.38, 1)
    strip.figs = { Figure(art), Figure(art), Figure(art) }
    strip:Hide()
    return strip
  end

  -- `strip` at `y` under the drawing's top, `h` tall.
  local function PlaceStrip(f, strip, y, h)
    strip:ClearAllPoints()
    strip:SetPoint("TOPLEFT", f, "TOPLEFT", 0, y)
    strip:SetHeight(h)
    strip.used = true
    strip:Show()
  end

  -- Caption `cap` centred at `x` with its top at `y`, the name `key`, marked
  -- when chosen; `w` wide (a third of the ground unless given).
  local function PaintCaption(f, cap, x, y, key, chosen, on, w)
    local T = ns.Theme
    local colW = w or Ctx.MinimapColumn()
    cap:ClearAllPoints()
    cap:SetPoint("TOP", f, "TOPLEFT", x, y)
    cap:SetWidth(colW)
    cap:SetText(L[key])
    T.SetColor(cap, (not on and "textDisabled") or (chosen and "textPrimary") or "textSecondary")
    if chosen then
      cap.Mark:SetWidth(math.min(TextW(cap), colW))
      T.FillColor(cap.Mark, on and "accent" or "textDisabled")
    end
    cap.Mark:SetShown(chosen)
    cap:Show()
  end

  local function HideCaption(cap)
    cap:Hide()
    cap.Mark:Hide()
  end

  -- The share of the ground's width a choice stands at: three to a row, a
  -- row of two between them.
  MM.THIRDS, MM.HALVES = { 1 / 6, 1 / 2, 5 / 6 }, { 1 / 3, 2 / 3 }

  function Ctx.minimap(card)
    local T = ns.Theme
    local f = CreateFrame("Frame", nil, card)
    f:SetPoint("TOPLEFT", card, "TOPLEFT", CTX_X, -CTX_TOP)
    f:SetSize(CTX_W, 4 + STAGE)
    local strips = { Strip(f), Strip(f), Strip(f) }
    -- The captions under the ground (Anchor's nine at the most) and the
    -- grid's situations, on the inspector's own ground and in its inks.
    local caps, labels = {}, {}
    for i = 1, 9 do
      local cap = Ctx.Caption(f)
      cap.Mark = f:CreateTexture(nil, "ARTWORK")
      cap.Mark:SetHeight(G.MARK_H)
      cap.Mark:SetPoint("TOP", cap, "BOTTOM", 0, -G.MARK_GAP)
      cap.Mark:Hide()
      cap:Hide()
      caps[i] = cap
    end
    for i = 1, 3 do
      local label = T.CreateText(f, "secondary")
      label:SetJustifyH("LEFT")
      label:SetWordWrap(true)
      if label.SetMaxLines then label:SetMaxLines(2) end
      label:SetWidth(CTX_W)
      label:Hide()
      labels[i] = label
    end

    f.Stop = function()
      for s = 1, #strips do
        local figs = strips[s].figs
        for i = 1, #figs do figs[i].Pulse:Stop() end
      end
    end
    f.Paint = function()
      local Icon = ns.MinimapButton
      local on = Icon and Icon.GetEnabled and Icon.GetEnabled() and true or false
      local mode = Ctx.MinimapMode()
      f.mode = mode
      local stageH, capRoom = Ctx.MinimapStage(), Ctx.MinimapCaptionRoom()
      f:SetHeight(4 + ((mode == "corner") and Ctx.MinimapAnchorHeight() or (stageH + capRoom)))
      local spec = Icon and Icon.GetIconSpec and Icon.GetIconSpec()
      for s = 1, #strips do strips[s]:SetAlpha(on and 1 or 0.4) end
      -- The words off, then what this drawing shows on; a figure or a strip
      -- it leaves out goes after, so a pulse that goes on is not started
      -- again.
      for i = 1, #caps do HideCaption(caps[i]) end
      for i = 1, #labels do labels[i]:Hide() end
      if spec then f.PaintFigures(Icon, spec, on, mode, stageH, capRoom) end
      for s = 1, #strips do
        local strip = strips[s]
        local figs = strip.figs
        for i = 1, #figs do
          if figs[i].used then figs[i].used = false else HideFigure(figs[i]) end
        end
        if strip.used then strip.used = false else strip:Hide() end
      end
    end
    -- What `mode` draws, from the icon as set.
    f.PaintFigures = function(Icon, spec, on, mode, stageH, capRoom)
      local P = FIG
      P.spec, P.on = spec, on
      P.glowOn, P.pulseOn, P.shadowOn = Icon.GetGlow() and true or false, Icon.GetPulse() and true or false,
        Icon.GetShadow() and true or false
      local glowId = Icon.GetGlowColor and Icon.GetGlowColor() or "gold"
      if Icon.GlowRGB then P.gr, P.gg, P.gb = Icon.GlowRGB(glowId) end
      local expiry = Icon.GetExpiry and Icon.GetExpiry() or "off"
      P.mark = expiry ~= "off"
      P.shape = Icon.GetMarker and Icon.GetMarker() or "dot"
      P.corner = Icon.GetMarkerCorner and Icon.GetMarkerCorner() or "TOPRIGHT"
      P.large = Icon.GetMarkerLarge and Icon.GetMarkerLarge() and true or false
      P.ox = Icon.GetMarkerX and Icon.GetMarkerX() or 0
      P.oy = Icon.GetMarkerY and Icon.GetMarkerY() or 0
      P.color = Icon.GetMarkerColor and Icon.GetMarkerColor() or "red"
      P.count = MM.COUNT[Icon.GetCount and Icon.GetCount() or "off"] or 0
      local getter = MM.GET[mode]
      local current = getter and Icon[getter] and Icon[getter]()
      if mode == "large" then current = current and "on" or "off" end
      local ids, keys = MM.IDS[mode], MM.CAPS[mode]
      local capY = -(4 + stageH + G.CAP_GAP)

      if mode == "set" then
        local strip = strips[1]
        PlaceStrip(f, strip, -4, stageH)
        PaintFigure(strip.figs[1], Icon, "lit", G.BIG, math.floor(G.AT_BIG * CTX_W + 0.5))
        local x = math.floor(G.AT_ACTUAL * CTX_W + 0.5)
        PaintFigure(strip.figs[2], Icon, "lit", (Icon.GetDrawnSize or Icon.GetIconSize)(), x)
        PaintCaption(f, caps[1], x, capY, keys[1], false, on)
      elseif mode == "show" then
        -- The grid, its foot on the captions; plain icons, the count and
        -- the marker left to the drawings that are about them.
        P.mark, P.count = false, 0
        local labelH = S.mmLabelH or 12
        local y = -4 - (stageH - GridHeight())
        for r = 1, 3 do
          local label = labels[r]
          label:ClearAllPoints()
          label:SetPoint("TOPLEFT", f, "TOPLEFT", 0, y)
          label:SetText(L[MM.ROWS[r]])
          T.SetColor(label, on and "textSecondary" or "textDisabled")
          label:Show()
          y = y - labelH - G.LABEL_GAP
          local strip = strips[r]
          PlaceStrip(f, strip, y, G.STRIP_H)
          for c = 1, 3 do
            local look = GridLook(r, ids[c])
            if look then PaintFigure(strip.figs[c], Icon, look, G.CELL, math.floor(MM.THIRDS[c] * CTX_W + 0.5)) end
          end
          y = y - G.STRIP_H - G.STRIP_GAP
        end
        for c = 1, 3 do
          PaintCaption(f, caps[c], math.floor(MM.THIRDS[c] * CTX_W + 0.5), capY, keys[c], ids[c] == current, on)
        end
      elseif mode == "large" then
        -- The marker on its own, as on the icon and larger, side by side.
        local strip = strips[1]
        PlaceStrip(f, strip, -4, stageH)
        for c = 1, 2 do
          local x = math.floor(MM.HALVES[c] * CTX_W + 0.5)
          P.large = c == 2
          PaintFigure(strip.figs[c], Icon, "alone", G.CHOICE, x)
          PaintCaption(f, caps[c], x, capY, keys[c], ids[c] == current, on)
        end
      elseif mode == "corner" then
        -- Anchor: the icon in a three by three grid, the marker at each
        -- spot, the centre in the middle; each row's names under its strip.
        P.mark = true
        local top = -4
        for r = 1, 3 do
          local strip = strips[r]
          PlaceStrip(f, strip, top, G.ANCHOR_STRIP)
          local row = MM.GRID[r]
          for c = 1, 3 do
            local i = row[c]
            if i > 0 then
              local x = math.floor(MM.THIRDS[c] * CTX_W + 0.5)
              P.corner = ids[i]
              PaintFigure(strip.figs[c], Icon, "lit", G.ANCHOR, x)
              PaintCaption(f, caps[i], x, top - G.ANCHOR_STRIP - G.CAP_GAP, keys[i], ids[i] == current, on)
            end
          end
          top = top - G.ANCHOR_STRIP - capRoom - G.ROW_GAP
        end
      elseif MM.ROWS2[mode] then
        -- Two rows: three over three (Shape, Color), three over two (Glow
        -- color), or as many as there are with no picker to offer Custom
        -- (two over two, three over two). Colours whether or not Glow or
        -- the marker is on: what each would be.
        local n = #ids
        if MM.PICKED[mode] and not S.mmGlowCustom then n = n - 1 end
        local split = (n == 4) and 2 or 3
        if mode == "marker" or mode == "color" then P.mark = true else P.glowOn = true end
        local rowH = math.floor((stageH + capRoom - G.ROW_GAP) / 2) - capRoom
        for r = 1, 2 do
          local strip = strips[r]
          local top = -4 - (r - 1) * (rowH + capRoom + G.ROW_GAP)
          PlaceStrip(f, strip, top, rowH)
          local first = (r == 1) and 1 or split + 1
          local count = (r == 1) and split or (n - split)
          local at = (count == 3) and MM.THIRDS or MM.HALVES
          for c = 1, count do
            local i = first + c - 1
            local x = math.floor(at[c] * CTX_W + 0.5)
            if mode == "marker" then
              P.shape = ids[i]
            elseif mode == "color" then
              P.color = ids[i]
            elseif Icon.GlowRGB then
              P.gr, P.gg, P.gb = Icon.GlowRGB(ids[i])
            end
            PaintFigure(strip.figs[c], Icon, "lit", G.CHOICE, x)
            PaintCaption(f, caps[i], x, top - rowH - G.CAP_GAP, keys[i], ids[i] == current, on,
              at == MM.HALVES and (math.floor(CTX_W / 2) - 4) or nil)
          end
        end
      else
        -- Three: Show marker's.
        local strip = strips[1]
        PlaceStrip(f, strip, -4, stageH)
        for c = 1, 3 do
          local x = math.floor(MM.THIRDS[c] * CTX_W + 0.5)
          local look = "lit"
          P.mark = c == 2
          if c == 3 then look = "alone" end
          PaintFigure(strip.figs[c], Icon, look, G.CHOICE, x)
          PaintCaption(f, caps[c], x, capY, keys[c], ids[c] == current, on)
        end
      end
    end
    return f
  end

  ---------------------------------------------------------
  -- Where the way into arranging sits
  --
  -- Shown under the arrange button's description: the Postbox window's
  -- title bar, its cog, and the mark beside it ringed in the accent.
  ---------------------------------------------------------
  local function Disc(parent, size, sublevel)
    local disc = parent:CreateTexture(nil, "ARTWORK", nil, sublevel)
    disc:SetSize(size, size)
    disc:SetTexture(WHITE)
    if type(parent.CreateMaskTexture) == "function" then
      local mask = parent:CreateMaskTexture()
      mask:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
      mask:SetAllPoints(disc)
      disc:AddMaskTexture(mask)
    end
    return disc
  end

  -- The drawing's height under the text, its gap included.
  function Ctx.ExtraHeight(kind)
    if kind == "pbAccent" then
      -- Room for its longest reading: the ratios, the lift and a near
      -- colour, each a line or two in a long language.
      local h = 8 + READOUT_LINES * Insp.TextHeight("0")
      local extra = S.accentReadout
      if extra then
        extra.height = h
        extra:SetHeight(h - 8)
      end
      return h
    end
    if kind ~= "arrange" then return 0 end
    local h = 8 + Insp.TextHeight(L["OPT_ARRANGE_WHERE"]) + 6 + MOCK_H
    local extra = S.arrangeMock
    if extra then
      extra.height = h
      extra:SetHeight(h - 8)
    end
    return h
  end

  function Ctx.Extra(kind)
    if kind == "pbAccent" then
      local extra = S.accentReadout
      if not extra then
        local say = S.say
        extra = CreateFrame("Frame", nil, say)
        extra:SetPoint("TOPLEFT", say.Text, "BOTTOMLEFT", 0, -8)
        extra:SetWidth(TEXT_W)
        local line = ns.Theme.CreateText(extra, "secondary")
        line:SetPoint("TOPLEFT", extra, "TOPLEFT", 0, 0)
        line:SetWidth(TEXT_W)
        line:SetJustifyH("LEFT")
        line:SetWordWrap(true)
        if line.SetSpacing then line:SetSpacing(2) end
        extra.Line = line
        S.accentReadout = extra
        Ctx.ExtraHeight(kind)
        extra:Hide()
      end
      -- Read now: the accent moves while the row is pointed at.
      extra.Line:SetText(Ctx.AccentReadout())
      return extra
    end
    if kind ~= "arrange" then return nil end
    local extra = S.arrangeMock
    if extra then return extra end
    local T = ns.Theme
    local say = S.say
    extra = CreateFrame("Frame", nil, say)
    extra:SetPoint("TOPLEFT", say.Text, "BOTTOMLEFT", 0, -8)
    extra:SetWidth(TEXT_W)
    local caption = T.CreateText(extra, "secondary")
    caption:SetPoint("TOPLEFT", extra, "TOPLEFT", 0, 0)
    caption:SetWidth(TEXT_W)
    caption:SetJustifyH("LEFT")
    caption:SetWordWrap(true)
    if caption.SetSpacing then caption:SetSpacing(2) end
    caption:SetText(L["OPT_ARRANGE_WHERE"])

    local bar = CreateFrame("Frame", nil, extra, "BackdropTemplate")
    bar:SetPoint("TOPLEFT", caption, "BOTTOMLEFT", 0, -6)
    bar:SetSize(TEXT_W, MOCK_H)
    bar:SetBackdrop(PLAIN_BACKDROP)
    local art = ArtHolder(bar)
    local cog = art:CreateTexture(nil, "ARTWORK")
    cog:SetSize(14, 14)
    cog:SetPoint("LEFT", bar, "LEFT", 8, 0)
    cog:SetTexture("Interface\\Buttons\\UI-OptionsButton")
    local ring = Disc(art, 20, 1)
    ring:SetPoint("LEFT", cog, "RIGHT", 4, 0)
    local hole = Disc(art, 17, 2)
    hole:SetPoint("CENTER", ring, "CENTER", 0, 0)
    T.SetGrey(hole, 0.02)
    local mark = Ctx.Mark(art, 12, "OVERLAY")
    if mark then
      mark:SetPoint("CENTER", ring, "CENTER", 0, 0)
      Ctx.TintMark(mark, 1, 1, 1, 1)
    end
    local title = T.CreateText(art, "bodySmall")
    title:SetPoint("CENTER", bar, "CENTER", 0, 0)
    title:SetText(L["FRAME_TITLE"])
    local close = art:CreateTexture(nil, "ARTWORK")
    close:SetSize(9, 9)
    close:SetPoint("RIGHT", bar, "RIGHT", -9, 0)
    local closeAtlas = T.FirstAtlas({ "uitools-icon-close", "transmog-icon-remove" })
    if closeAtlas then close:SetAtlas(closeAtlas, false) else close:Hide() end
    T.SetColor(close, "textSecondary")

    extra.Cog, extra.Ring, extra.Bar = cog, ring, bar
    S.arrangeMock = extra
    Ctx.ExtraHeight(kind)
    Ctx.PaintExtra()
    extra:Hide()
    return extra
  end

  -- The accent the mock wears, from the live accent.
  function Ctx.PaintExtra()
    local extra = S.arrangeMock
    if not extra then return end
    local T = ns.Theme
    local r, g, b = T.GetAccent()
    extra.Cog:SetVertexColor(r, g, b)
    extra.Ring:SetVertexColor(r, g, b, 1)
    -- The title bar it sketches: near black, or its light twin.
    local v = T.Grey(0.02)
    local e = T.Colors.insetEdge
    extra.Bar:SetBackdropColor(v, v, v, 1)
    extra.Bar:SetBackdropBorderColor(e[1], e[2], e[3], e[4])
  end
end

-------------------------------------------------------------
-- Rows
--
-- The list is built from a handful of row kinds, all read the same way: a
-- checkbox, a dropdown, a push button, a pair of checkboxes side by side, a
-- quiet note. Each row, or half-row, is a cell: it
-- washes while the pointer is on it and hands the inspector its entry. The
-- scripts are shared -- a cell and its control carry what they need on
-- themselves -- so a hover builds no closure and no table.
--
-- A column is where rows go: a page of the list, or a block inside one
-- whose rows grey with a feature's switch.
-------------------------------------------------------------
do
  function Rows.Hover(cell, entry)
    local washed = S.washed
    if washed ~= cell then
      if washed and washed.Wash then washed.Wash:Hide() end
      S.washed = cell
      if cell.Wash then cell.Wash:Show() end
    end
    if cell.onHover then cell.onHover(cell) end
    Insp.Show(entry or cell.entry)
  end

  -- The pointer left a cell. Its wash goes unless the pointer only moved
  -- onto the cell's own control; the inspector keeps its text while the
  -- pointer is anywhere over the list or the inspector (see above).
  function Rows.Unhover(cell)
    if S.washed == cell and not cell:IsMouseOver() then
      if cell.Wash then cell.Wash:Hide() end
      S.washed = nil
    end
    local body = S.body
    if not (body and body:IsMouseOver()) then Insp.Show(nil) end
  end

  -- While a dropdown's list is open, its row holds the panel: its wash and
  -- the inspector stay on it wherever the pointer goes -- over the list, the
  -- rows around it, the inspector's tiles -- and nothing else lights or
  -- shows a tooltip. Where the pointer comes to rest meanwhile is kept, with
  -- the enter that would have run for it, and that enter runs when the list
  -- closes (Rows.Release): the row under the pointer answers at once, the
  -- pointer need not move. Checked by every enter and leave below, so
  -- nothing runs while no list is open but a comparison.
  --
  -- Answers whether the hold took the pointer's arrival on `frame`.
  function Rows.Held(frame, enter)
    local held = S.held
    if not held or frame == held or frame.__pbCell == held then return false end
    S.heldAt, S.heldEnter = frame, enter
    return true
  end

  -- The pointer left `frame` while a list holds the panel; the owner row
  -- included, which keeps its wash and the inspector. Answers whether the
  -- hold took it.
  function Rows.HeldLeave(frame)
    if not S.held then return false end
    if S.heldAt == frame then S.heldAt, S.heldEnter = nil, nil end
    return true
  end

  function Rows.Hold(cell)
    S.held, S.heldAt, S.heldEnter = cell, nil, nil
    Rows.Hover(cell)
  end

  function Rows.Release(cell)
    if S.held ~= cell then return end
    local at, enter = S.heldAt, S.heldEnter
    S.held, S.heldAt, S.heldEnter = nil, nil, nil
    if at and at:IsVisible() and at:IsMouseOver() then
      enter(at)
    else
      -- On the list, the row itself, or out of the panel: the row's leave,
      -- judged now; the client enters whatever the closed list uncovers.
      Rows.Unhover(cell)
    end
  end

  -- A dropdown's onList (Lib/UI/Dropdown.lua).
  local function ListShown(dd, open)
    local cell = dd.__pbCell
    if not cell then return end
    if open then Rows.Hold(cell) else Rows.Release(cell) end
  end

  local function CellEnter(self)
    if Rows.Held(self, CellEnter) then return end
    Rows.Hover(self)
  end

  local function CellLeave(self)
    if Rows.HeldLeave(self) then return end
    Rows.Unhover(self)
  end

  -- A control: the inspector for its cell (or its own entry, where it has
  -- one), and its tooltip.
  local function ControlEnter(self)
    if Rows.Held(self, ControlEnter) then return end
    local cell = self.__pbCell
    Rows.Hover(cell, self.__pbEntry)
    Tip.Entry(self, self.__pbEntry or cell.entry)
  end

  local function ControlLeave(self)
    GameTooltip:Hide()
    if Rows.HeldLeave(self) then return end
    Rows.Unhover(self.__pbCell)
  end

  Rows.ControlEnter, Rows.ControlLeave = ControlEnter, ControlLeave

  -- A row with a tooltip of its own leaving: the tooltip goes with it.
  function Rows.LeaveRow(self)
    GameTooltip:Hide()
    if Rows.HeldLeave(self) then return end
    Rows.Unhover(self)
  end

  local function CheckSound(on)
    if type(SOUNDKIT) == "table" then
      PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                   or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    end
  end

  local function CheckClick(self)
    local cell = self.__pbCell
    local on = self:GetChecked() and true or false
    cell.set(on)
    if cell.after then cell.after(on) end
    CheckSound(on)
  end

  -- A column keeps what it stacks, in order (`items`: a frame and the height
  -- it takes), so Rows.Reflow can stack it again when a row's height moves.
  function Rows.Column(parent)
    return { frame = parent, y = -LIST_PAD, top = -LIST_PAD, first = true, cells = {}, items = {} }
  end

  -- A block of rows in `col` that greys as one, its group headings with
  -- them: what a feature's switch governs. Rows.EndBlock closes it and
  -- moves `col` past it. `why`, a locale key: what each of its rows says
  -- while the block is grey -- what turns it on (Rows.Why).
  function Rows.Block(col, why)
    local frame = CreateFrame("Frame", nil, col.frame)
    frame:SetPoint("TOPLEFT", col.frame, "TOPLEFT", 0, col.y)
    frame:SetPoint("TOPRIGHT", col.frame, "TOPRIGHT", 0, col.y)
    local block = { frame = frame, y = 0, top = 0, first = col.first, cells = {}, items = {}, heads = {}, parent = col,
      why = why }
    block.item = { frame = frame, h = 0, block = block }
    col.items[#col.items + 1] = block.item
    return block
  end

  function Rows.EndBlock(block)
    local col = block.parent
    block.frame:SetHeight(math.max(1, -block.y))
    block.item.h = -block.y
    col.y = col.y + block.y
    col.first = block.first
    -- Each setting in it says what turns the block on while it is grey; a
    -- note is not a setting, and says only what it says.
    local why = block.why and L[block.why]
    if why then
      for i = 1, #block.cells do
        local cell = block.cells[i]
        local entry = cell.entry
        if cell.kind ~= "note" and entry then
          entry.onText = entry.onText or entry.text
          entry.blockText = entry.onText .. "\n\n" .. why
        end
      end
    end
    return block
  end

  -- A grey row says why: under its description, one line saying what
  -- turns it on (`key`, a locale key), while another setting has it grey
  -- (Rows.SetEnabled). Written here, once, and measured with every text
  -- (Insp.Need): greying a row builds no string.
  function Rows.Why(cell, key)
    local entry = cell.entry
    entry.onText = entry.onText or entry.text
    entry.offText = entry.onText .. "\n\n" .. L[key]
  end

  -- A row `height` tall at the column's cursor, under a hairline unless it
  -- opens the page or a group.
  function Rows.New(col, height)
    local row = CreateFrame("Frame", nil, col.frame)
    row:SetHeight(height)
    row:SetPoint("TOPLEFT", col.frame, "TOPLEFT", 0, col.y)
    row:SetPoint("TOPRIGHT", col.frame, "TOPRIGHT", 0, col.y)
    if not col.first then
      local line = row:CreateTexture(nil, "BORDER")
      line:SetHeight(1)
      line:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
      line:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
      ns.Theme.FillChrome(line, HAIR_A)
    end
    row.item = { frame = row, h = height }
    col.items[#col.items + 1] = row.item
    col.y = col.y - height
    col.first = false
    return row
  end

  -- Stacks `col` again, top down, each frame at the height its item now
  -- takes, a block from its own rows; a hidden row takes none, as the
  -- border size's row stands aside (State.BorderSize). Answers the height
  -- used. Run only on a page a pair has changed on (Rows.FitPairs), so a
  -- page nothing moves on is never touched.
  function Rows.Reflow(col)
    local y = col.top
    local items = col.items
    for i = 1, #items do
      local item = items[i]
      local f = item.frame
      if item.block then
        item.h = Rows.Reflow(item.block)
        f:SetHeight(math.max(1, item.h))
      end
      f:ClearAllPoints()
      f:SetPoint("TOPLEFT", col.frame, "TOPLEFT", 0, y)
      f:SetPoint("TOPRIGHT", col.frame, "TOPRIGHT", 0, y)
      if f:IsShown() then y = y - item.h end
    end
    return col.top - y
  end

  -- Makes `cell` (a row, or half of one, `width` wide) a place the pointer
  -- rests: its wash, its name, its entry. Motion only: a click passes on,
  -- so the panel still drags from anywhere on the list.
  function Rows.Cell(col, cell, width, title, text, role)
    local T = ns.Theme
    local wash = cell:CreateTexture(nil, "BACKGROUND")
    wash:SetAllPoints()
    T.FillChrome(wash, WASH_A)
    wash:Hide()
    local name = T.CreateText(cell, role or "label")
    name:SetPoint("LEFT", cell, "LEFT", NAME_X, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    name:SetText(title)
    cell.Wash, cell.Name, cell.nameText, cell.w = wash, name, title, width
    cell.entry = Entry(title, text)
    cell.kind = "plain"
    cell:EnableMouse(true)
    if cell.SetPropagateMouseClicks then cell:SetPropagateMouseClicks(true) end
    cell:SetScript("OnEnter", CellEnter)
    cell:SetScript("OnLeave", CellLeave)
    S.cells[#S.cells + 1] = cell
    col.cells[#col.cells + 1] = cell
    return cell
  end

  -- A control's shared scripts, and what it needs to find its cell.
  local function Wire(control, cell, hook)
    control.__pbCell = cell
    if control.SetMotionScriptsWhileDisabled then control:SetMotionScriptsWhileDisabled(true) end
    if hook then
      control:HookScript("OnEnter", ControlEnter)
      control:HookScript("OnLeave", ControlLeave)
    else
      control:SetScript("OnEnter", ControlEnter)
      control:SetScript("OnLeave", ControlLeave)
    end
  end

  local function AddCheck(cell, spec)
    local cb = CreateFrame("CheckButton", nil, cell, "UICheckButtonTemplate")
    cb:SetSize(CHECK_H, CHECK_H)
    cb:SetPoint("RIGHT", cell, "RIGHT", -CONTROL_R, 0)
    -- What the skins look for: a house checkbox, and the caption they
    -- re-font with it.
    cb.__postboxCheck = true
    cb.__label = cell.Name
    Wire(cb, cell)
    cb:SetScript("OnClick", CheckClick)
    cell.kind, cell.control, cell.controlW = "check", cb, CHECK_H
    cell.get, cell.set, cell.after = spec.get, spec.set, spec.after
    local ok, on = pcall(spec.get)
    cb:SetChecked(ok and on and true or false)
    return cb
  end

  -- spec: title, text, get, set [, after(on)] [, master] [, entryTitle]
  function Rows.Check(col, spec)
    local row = Rows.New(col, spec.master and MASTER_H or ROW_H)
    Rows.Cell(col, row, ROW_W, spec.title, spec.text)
    if spec.master then
      -- A feature's switch reads a step up from the rows it governs.
      if _G.GameFontNormal then row.Name:SetFontObject(ns.Theme.HostFont(_G.GameFontNormal)) end
      ns.Theme.SetColor(row.Name, "accent")
    end
    if spec.entryTitle then row.entry.title = spec.entryTitle end
    AddCheck(row, spec)
    return row
  end

  -- Two checkboxes side by side, each a cell of its own -- or, where either
  -- name will not fit its half (Rows.FitPairs), one under the other, each
  -- a whole row, under a hairline of its own.
  function Rows.Pair(col, a, b)
    local row = Rows.New(col, ROW_H)
    local half = ROW_W / 2
    local cells = {}
    for i = 1, 2 do
      local spec = (i == 1) and a or b
      local cell = CreateFrame("Frame", nil, row)
      cell:SetPoint("TOPLEFT", row, "TOPLEFT", (i - 1) * half, 0)
      cell:SetSize(half, ROW_H)
      Rows.Cell(col, cell, half, spec.title, spec.text)
      AddCheck(cell, spec)
      cells[i] = cell
    end
    local mid = row:CreateTexture(nil, "BORDER")
    mid:SetWidth(1)
    mid:SetPoint("TOPLEFT", row, "TOPLEFT", half, 0)
    mid:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", half, 0)
    ns.Theme.FillChrome(mid, HAIR_A)
    local line = cells[2]:CreateTexture(nil, "BORDER")
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", cells[2], "TOPLEFT", 0, 0)
    line:SetPoint("TOPRIGHT", cells[2], "TOPRIGHT", 0, 0)
    ns.Theme.FillChrome(line, HAIR_A)
    line:Hide()
    row.pair = { cells[1], cells[2], mid, line }
    row.unpaired = false
    local page = col
    while page.parent do page = page.parent end
    row.page = page
    S.pairs[#S.pairs + 1] = row
    return row
  end

  -- A pair side by side, or (`apart`) one under the other.
  local function LayPair(row, apart)
    local p = row.pair
    local w = apart and ROW_W or ROW_W / 2
    p[1]:SetSize(w, ROW_H)
    p[1].w = w
    p[2]:ClearAllPoints()
    p[2]:SetPoint("TOPLEFT", row, "TOPLEFT", apart and 0 or w, apart and -ROW_H or 0)
    p[2]:SetSize(w, ROW_H)
    p[2].w = w
    p[3]:SetShown(not apart)
    p[4]:SetShown(apart)
    local h = apart and 2 * ROW_H or ROW_H
    row:SetHeight(h)
    row.item.h = h
    row.unpaired = apart
  end

  -- Measured on every open, before the names are fitted: a pair stays side
  -- by side while both names fit their halves, the normal case, and comes
  -- apart only where one will not -- a long translation, a wide host font --
  -- and back together once both fit again. Its page is stacked again, and
  -- the list's height follows (Layout). Answers whether anything moved.
  function Rows.FitPairs()
    local pairs_ = S.pairs
    local room = ROW_W / 2 - NAME_X - CONTROL_R - CHECK_H - NAME_GAP
    local moved
    for i = 1, #pairs_ do
      local row = pairs_[i]
      local apart = false
      for j = 1, 2 do
        local cell = row.pair[j]
        cell.Name:SetText(cell.nameText)
        if TextW(cell.Name) > room then apart = true end
      end
      if apart ~= row.unpaired then
        LayPair(row, apart)
        moved = moved or {}
        moved[row.page] = true
      end
    end
    if not moved then return false end
    local need = 0
    for key, page in pairs(S.pages) do
      local col = S.cols[key]
      if moved[col] then
        S.pageH[key] = Rows.Reflow(col) + 2 * LIST_PAD
        page:SetHeight(S.pageH[key])
      end
      if S.pageH[key] + 2 > need then need = S.pageH[key] + 2 end
    end
    S.listNeed = need
    return true
  end

  -- Reflects the stored value in the toggle's caption.
  function Rows.PaintDropdown(cell)
    local ok, current = pcall(cell.get)
    if not ok then return end
    local items = cell.items
    for i = 1, #items do
      local item = items[i]
      if item.id == current then
        cell.dd._selectedId = current
        cell.dd:SetText(item.name)
        if cell.dd.PaintSwatch then cell.dd:PaintSwatch() end
        return
      end
    end
  end

  -- A dropdown with nothing written about it says what it offers.
  local function Choices(items)
    local names = {}
    for i = 1, #items do names[i] = items[i].name end
    return table.concat(names, "  \194\183  ")
  end

  -- Postbox's own dropdown element, not UIDropDownMenu / MenuUtil, so the
  -- list panel is a frame we own and can keep fully opaque. spec: title,
  -- text, items, get, set(id).
  function Rows.Dropdown(col, spec)
    local row = Rows.New(col, ROW_H)
    Rows.Cell(col, row, ROW_W, spec.title, spec.text or Choices(spec.items))
    local ok, current = pcall(spec.get)
    local dd = ns.Core.UI.Dropdown.Create(row, {
      items        = spec.items,
      toggleWidth  = DD_W,
      toggleHeight = DD_H,
      alignRight   = true,
      height       = DD_H + 2,
      defaultId    = ok and current or nil,
      swatchFor    = spec.swatchFor,
      onList       = ListShown,
    })
    dd.__pbCell = row
    dd:SetPoint("RIGHT", row, "RIGHT", -CONTROL_R, 0)
    dd:SetWidth(DD_W)
    dd:SetChangeCallback(spec.set)
    local toggle = dd._toggle
    Wire(toggle, row, true)
    row.kind, row.control, row.dd, row.items = "dropdown", toggle, dd, spec.items
    row.get, row.controlW = spec.get, DD_W
    Rows.PaintDropdown(row)
    return row
  end

  -- A slider: a whole number from spec.min to spec.max, as wide as a
  -- dropdown and where one stands. The game's own Slider does the dragging
  -- and the click on the track (nothing runs between two changes); Postbox
  -- draws it: a chrome track with a tick at zero, the thumb in the accent
  -- (the value chosen, as a chosen segment wears it), and the value beside
  -- it, signed ("+2", "-1", "0"). Grey, the thumb and the value take the
  -- disabled grey. While the thumb is held its row holds the panel, as a
  -- dropdown's open list does (Rows.Hold), so the inspector and the drawing
  -- stay on it wherever the pointer drifts. Each value's words are made
  -- once, when the row is built: a drag builds no string.
  -- spec: title, text, min, max, get, set(v) [, after(v)].
  local SLIDER = { VALUE_W = 28, GAP = 6, H = 16, THUMB_W = 6, THUMB_H = 14, TRACK_H = 2, TICK_H = 8 }
  local signed = {}
  local function Signed(v)
    local s = signed[v]
    if not s then
      s = (v > 0) and ("+" .. v) or tostring(v)
      signed[v] = s
    end
    return s
  end

  local function SliderLook(cell, on)
    local T = ns.Theme
    T.FillColor(cell.thumb, on and "accent" or "textDisabled")
    T.SetColor(cell.Value, on and "textPrimary" or "textDisabled")
    if on then cell.slider:Enable() else cell.slider:Disable() end
  end

  local function SliderChanged(self, value)
    local cell = self.__pbCell
    local v = math.floor((tonumber(value) or 0) + 0.5)
    if v == cell.value then return end
    cell.value = v
    cell.Value:SetText(Signed(v))
    if cell.painting then return end
    cell.set(v)
    if cell.after then cell.after(v) end
  end

  local function SliderDown(self)
    if self:IsEnabled() then Rows.Hold(self.__pbCell) end
  end

  local function SliderUp(self)
    Rows.Release(self.__pbCell)
  end

  -- Reflects the stored value in the slider and its words.
  function Rows.PaintSlider(cell)
    local ok, v = pcall(cell.get)
    if not ok then return end
    v = math.floor((tonumber(v) or 0) + 0.5)
    cell.painting = true
    cell.slider:SetValue(v)
    cell.painting = false
    if cell.value ~= v then
      cell.value = v
      cell.Value:SetText(Signed(v))
    end
  end

  function Rows.Slider(col, spec)
    local T = ns.Theme
    local row = Rows.New(col, ROW_H)
    Rows.Cell(col, row, ROW_W, spec.title, spec.text)
    local lo, hi = spec.min, spec.max
    for v = lo, hi do Signed(v) end
    local value = T.CreateText(row, "label")
    value:SetJustifyH("RIGHT")
    value:SetWordWrap(false)
    value:SetWidth(SLIDER.VALUE_W)
    value:SetPoint("RIGHT", row, "RIGHT", -CONTROL_R, 0)
    local w = DD_W - SLIDER.VALUE_W - SLIDER.GAP
    local s = CreateFrame("Slider", nil, row)
    s:SetSize(w, SLIDER.H)
    s:SetPoint("RIGHT", value, "LEFT", -SLIDER.GAP, 0)
    s:SetOrientation("HORIZONTAL")
    s:SetMinMaxValues(lo, hi)
    s:SetValueStep(1)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    local half = SLIDER.THUMB_W / 2
    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetHeight(SLIDER.TRACK_H)
    track:SetPoint("LEFT", s, "LEFT", half, 0)
    track:SetPoint("RIGHT", s, "RIGHT", -half, 0)
    T.FillChrome(track, 0.25)
    local tick = s:CreateTexture(nil, "BORDER")
    tick:SetSize(1, SLIDER.TICK_H)
    tick:SetPoint("CENTER", s, "LEFT", half + (w - SLIDER.THUMB_W) * (0 - lo) / (hi - lo), 0)
    T.FillChrome(tick, 0.5)
    -- The thumb as the house's scroll bar makes its own (Theme.SlimScrollBar).
    s:SetThumbTexture(WHITE)
    local thumb = s:GetThumbTexture()
    thumb:SetDrawLayer("OVERLAY")
    thumb:SetSize(SLIDER.THUMB_W, SLIDER.THUMB_H)
    Wire(s, row)
    s:SetScript("OnValueChanged", SliderChanged)
    s:SetScript("OnMouseDown", SliderDown)
    s:SetScript("OnMouseUp", SliderUp)
    s:SetScript("OnHide", SliderUp)
    row.kind, row.control, row.slider, row.thumb, row.Value = "slider", s, s, thumb, value
    row.get, row.set, row.after, row.controlW = spec.get, spec.set, spec.after, DD_W
    SliderLook(row, true)
    Rows.PaintSlider(row)
    return row
  end

  -- A push button on the right. spec: title, text, caption, onClick
  -- [, onHover(cell)] [, mark] [, minWidth]: `mark` puts the way into
  -- arranging's mark before the caption, the two centred as one (Rows.Fit
  -- sizes the button to both); `minWidth`, the least it is, however short
  -- its caption.
  function Rows.Button(col, spec)
    local row = Rows.New(col, ROW_H)
    Rows.Cell(col, row, ROW_W, spec.title, spec.text)
    local btn = ns.Theme.CreateButton(nil, row)
    btn:SetHeight(BUTTON_H)
    btn:SetPoint("RIGHT", row, "RIGHT", -CONTROL_R, 0)
    btn:SetText(spec.caption)
    btn:SetScript("OnClick", spec.onClick)
    Wire(btn, row, true)
    -- On a holder of its own: a skin's button repaint fades the button's
    -- own textures.
    if spec.mark then btn.Mark = Ctx.Mark(ArtHolder(btn), 12) end
    row.kind, row.control, row.button, row.onHover = "button", btn, btn, spec.onHover
    row.minW = spec.minWidth
    return row
  end

  -- A quiet line across the row, centred: something to know, not a setting.
  function Rows.Note(col, text, title, desc)
    local row = Rows.New(col, ROW_H)
    Rows.Cell(col, row, ROW_W, title, desc, "secondary")
    row.Name:ClearAllPoints()
    row.Name:SetPoint("CENTER", row, "CENTER", 0, 0)
    row.Name:SetJustifyH("CENTER")
    row.Name:SetText(text)
    row.nameText = text
    row.kind = "note"
    -- The line is all there is to point at, so it carries the tooltip the
    -- line always had.
    row.__pbCell = row
    row:SetScript("OnEnter", ControlEnter)
    row:SetScript("OnLeave", ControlLeave)
    return row
  end

  -- A group's heading: its name and a rule in the accent to the row's end.
  -- The rule is the accent as a mark (Theme's "accent" on a texture): the
  -- contrast guard's tone, 3:1 on the plates the list's own ground is
  -- darker than (lighter, on a light palette), drawn solid, so it reads in
  -- every look -- Light mode, a pale or dark host accent, EllesmereUI's
  -- white -- where the accent at a third of its alpha all but vanished.
  function Rows.Group(col, title)
    local T = ns.Theme
    local head = CreateFrame("Frame", nil, col.frame)
    head:SetHeight(GROUP_H)
    head:SetPoint("TOPLEFT", col.frame, "TOPLEFT", 0, col.y)
    head:SetPoint("TOPRIGHT", col.frame, "TOPRIGHT", 0, col.y)
    local text = T.CreateText(head, "heading")
    text:SetPoint("BOTTOMLEFT", head, "BOTTOMLEFT", NAME_X, 5)
    text:SetWordWrap(false)
    text:SetText(title)
    col.items[#col.items + 1] = { frame = head, h = GROUP_H }
    local rule = head:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetPoint("LEFT", text, "RIGHT", NAME_GAP, -1)
    T.FillColor(rule, "accent")
    head.Text, head.Rule = text, rule
    S.groups[#S.groups + 1] = head
    if col.heads then col.heads[#col.heads + 1] = head end
    col.y = col.y - GROUP_H
    col.first = true
    return head
  end

  -- A heading in the accent, or grey with its block's rows (head.off).
  function Rows.PaintGroup(head)
    local T = ns.Theme
    T.SetColor(head.Text, head.off and "textDisabled" or "accent")
    T.FillColor(head.Rule, head.off and "textDisabled" or "accent")
  end

  -- Greyed in colour and alpha together, and not clickable; its motion
  -- scripts stay, so the inspector and the tooltip still say what it does.
  -- Where it can say why it is grey (Rows.Why, Rows.Block), its text says
  -- it: what turns its block on while the block is grey, else what turns
  -- the row on. The inspector says it again where it is showing it.
  function Rows.SetEnabled(cell, on)
    local control = cell.control
    if cell.kind == "slider" then
      SliderLook(cell, on)
    elseif control and control.SetEnabled then
      control:SetEnabled(on)
    end
    local more = cell.more
    if more and more.SetEnabled then more:SetEnabled(on) end
    if cell.kind ~= "note" and cell.Name then
      ns.Theme.SetColor(cell.Name, on and "accent" or "textDisabled")
    end
    local entry = cell.entry
    local text = entry and entry.onText
    if not text then return end
    if not on then
      if cell.blockOff then text = entry.blockText or text else text = entry.offText or text end
    end
    if entry.text ~= text then
      entry.text = text
      if S.shown == entry then
        S.shown = false
        Insp.Show(entry)
      end
    end
  end

  -- Its rows' names and controls in their disabled colours, at full
  -- strength: a text dimmed by its alpha is read on whatever it lets through.
  function Rows.SetBlock(block, on)
    if not block then return end
    for i = 1, #block.cells do
      local cell = block.cells[i]
      cell.blockOff = not on
      Rows.SetEnabled(cell, on)
    end
    local heads = block.heads
    for i = 1, #heads do
      heads[i].off = not on
      Rows.PaintGroup(heads[i])
    end
    if not on then ns.Core.UI.Dropdown.CloseAll() end
  end

  -- A push button sized to its caption, as its own font draws it now, and
  -- to the mark before it where it has one, the two centred as one; never
  -- narrower than the row's minW, and wider wherever its caption needs it,
  -- so no translation is cut short. The caption keeps no width of its own:
  -- a button puts its state's font back on it at every enable and disable,
  -- and a width frozen in one font cut the caption short in another.
  -- Answers the button's width.
  local function FitButton(cell)
    local T = ns.Theme
    local btn = cell.control
    local width = T.SizeToText(btn, BUTTON_FIT)
    local mark = btn.Mark
    local lead = mark and (mark.w + 6) or 0
    local want = math.max(cell.minW or 0, width + lead)
    if want ~= width then btn:SetWidth(want) end
    width = want
    if not mark then return width end
    local fs = btn:GetFontString()
    if fs then
      fs:ClearAllPoints()
      fs:SetPoint("CENTER", btn, "CENTER", lead / 2, 0)
      mark:ClearAllPoints()
      mark:SetPoint("CENTER", fs, "LEFT", -(6 + mark.w / 2), 0)
    end
    return width
  end

  -- Measured on every open, after the skins have had their say about
  -- fonts, and in whatever language the client speaks, and again after a
  -- font change (the skins' RefitScreens). The normal case keeps its look:
  -- a pair whose name will not fit its half comes apart (Rows.FitPairs); a
  -- dropdown is DD_W wide unless its widest value will not fit that, and
  -- then as wide as that value needs (the select's FitWidth), it alone; a
  -- name that would reach the dropdown beside it narrows that toggle, down
  -- to DD_MIN_W, and only past that is the name cut short -- the
  -- inspector's title still carries it whole.
  function Rows.Fit()
    local T = ns.Theme
    Rows.FitPairs()
    local cells = S.cells
    for i = 1, #cells do
      local cell = cells[i]
      local kind = cell.kind
      local inner = cell.w - NAME_X - CONTROL_R
      if kind == "note" then
        T.FitText(cell.Name, inner - NAME_X, cell.nameText, cell)
      elseif kind == "hidden" then
        State.FitHidden()
      else
        local controlW = cell.controlW or 0
        if kind == "dropdown" then
          local full = cell.dd.FitWidth and cell.dd:FitWidth() or DD_W
          local want = full
          local nameW = TextW(cell.Name)
          if nameW + NAME_GAP + full > inner then
            want = math.max(DD_MIN_W, inner - nameW - NAME_GAP)
          end
          if cell.controlW ~= want then
            cell.controlW = want
            cell.dd:SetWidth(want)
            cell.control:SetWidth(want)
          end
          controlW = want
        elseif kind == "button" then
          controlW = FitButton(cell)
        end
        T.FitText(cell.Name, inner - controlW - NAME_GAP, cell.nameText, cell)
      end
    end
    for i = 1, #S.groups do
      local head = S.groups[i]
      head.Rule:SetWidth(math.max(0, ROW_W - NAME_X - CONTROL_R - NAME_GAP - TextW(head.Text)))
      T.FillColor(head.Rule, head.off and "textDisabled" or "accent")
    end
  end
end

-------------------------------------------------------------
-- Tabs
--
-- Five house plates, like the window's own segments: the selected one in
-- the accent, the others neutral. The two tabs a feature's switch leads,
-- Minimap and Mail Memory, carry a small square beside their name that
-- says whether the feature is on: green on, a grey ring off. Window has
-- none: no one switch is what that tab is about (whose look the window
-- wears is the dot on its inspector's host badge).
-------------------------------------------------------------
do
  local function TabClick(self)
    if S.tab ~= self.key then Panel.SelectTab(self.key) end
  end

  -- Only a caption cut short has anything to add.
  local function TabEnter(self)
    if self.__pbOverflowText then
      local T = ns.Theme
      T.TipBegin(self, "ANCHOR_BOTTOM")
      T.TipTitle(self.__pbOverflowText)
      GameTooltip:Show()
    end
  end

  local function TabLeave(self)
    if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
  end

  local function AddSquare(plate)
    local sq = CreateFrame("Frame", nil, plate)
    sq:SetSize(8, 8)
    sq.Fill = sq:CreateTexture(nil, "OVERLAY")
    sq.Fill:SetAllPoints()
    local ring = {}
    for i = 1, 4 do
      ring[i] = sq:CreateTexture(nil, "OVERLAY")
      ring[i]:SetColorTexture(0.54, 0.54, 0.58, 1)
    end
    ring[1]:SetPoint("TOPLEFT", sq, "TOPLEFT", 0, 0)
    ring[1]:SetPoint("TOPRIGHT", sq, "TOPRIGHT", 0, 0)
    ring[1]:SetHeight(1)
    ring[2]:SetPoint("BOTTOMLEFT", sq, "BOTTOMLEFT", 0, 0)
    ring[2]:SetPoint("BOTTOMRIGHT", sq, "BOTTOMRIGHT", 0, 0)
    ring[2]:SetHeight(1)
    ring[3]:SetPoint("TOPLEFT", sq, "TOPLEFT", 0, -1)
    ring[3]:SetPoint("BOTTOMLEFT", sq, "BOTTOMLEFT", 0, 1)
    ring[3]:SetWidth(1)
    ring[4]:SetPoint("TOPRIGHT", sq, "TOPRIGHT", 0, -1)
    ring[4]:SetPoint("BOTTOMRIGHT", sq, "BOTTOMRIGHT", 0, 1)
    ring[4]:SetWidth(1)
    sq.Ring = ring
    sq:Hide()
    plate.Square = sq
  end

  function Tabs.Build(frame)
    local T = ns.Theme
    local edges = T.ColumnEdges(PANEL_W - 2 * EDGE, #TABS, TAB_GAP)
    for i = 1, #TABS do
      local spec = TABS[i]
      local plate = T.CreatePlate(frame, "tab")
      plate:SetHeight(TAB_H)
      plate:SetWidth(edges[i].width)
      plate:SetPoint("TOPLEFT", frame, "TOPLEFT", EDGE + edges[i].left, -TOP)
      plate.key, plate.caption = spec.key, L[spec.caption]
      plate:SetText(plate.caption)
      plate:SetScript("OnClick", TabClick)
      plate:HookScript("OnEnter", TabEnter)
      plate:HookScript("OnLeave", TabLeave)
      if spec.square then AddSquare(plate) end
      -- Under the Postbox style, the window tabs' plates (the options
      -- mockup's tabs): dark idle, a lit plate selected, a ring each.
      local skin = ns.Skin
      if skin and type(skin.StyleTabPlate) == "function" then skin.StyleTabPlate(plate) end
      S.plates[spec.key] = plate
    end
  end

  -- The caption, cut to its plate where a translation will not fit, and
  -- centred with its square as one.
  local function FitOne(plate)
    local T = ns.Theme
    local sq = plate.Square
    local withSquare = sq and sq:IsShown()
    local room = (plate:GetWidth() or 0) - 12 - (withSquare and 14 or 0)
    local text = plate.Text
    T.FitText(text, room, plate.caption, plate)
    text:SetWidth(math.min(TextW(text), room))
    text:ClearAllPoints()
    text:SetPoint("CENTER", plate, "CENTER", withSquare and -7 or 0, 0)
    if withSquare then
      sq:ClearAllPoints()
      sq:SetPoint("LEFT", text, "RIGHT", 6, 0)
    end
  end

  -- Measured on every open. The strip is shared out evenly, the normal
  -- case; only where a caption and its square need more than an even share
  -- (a long translation) does that tab take what it needs, the rest
  -- sharing what is left evenly -- and if even that cannot hold every
  -- caption, the shares go back to even and a caption is cut, its tooltip
  -- carrying it whole.
  function Tabs.Fit()
    local T = ns.Theme
    local n = #TABS
    local strip = PANEL_W - 2 * EDGE
    local edges = T.ColumnEdges(strip, n, TAB_GAP, S.tabEdges)
    S.tabEdges = edges
    local need, fixed = S.tabNeed, S.tabFixed
    local even = (strip - (n - 1) * TAB_GAP) / n
    local over = false
    for i = 1, n do
      local plate = S.plates[TABS[i].key]
      local text, sq = plate.Text, plate.Square
      text:SetText(plate.caption)
      need[i] = TextW(text) + 12 + ((sq and sq:IsShown()) and 14 or 0)
      fixed[i] = false
      if need[i] > even then over = true end
    end
    if over then
      -- Fix every tab whose need is over the share of the room still
      -- unfixed, until none is; at most n passes.
      local room, left = strip - (n - 1) * TAB_GAP, n
      for _ = 1, n do
        local share = room / left
        local any = false
        for i = 1, n do
          if not fixed[i] and need[i] > share then
            fixed[i], any = true, true
            room, left = room - need[i], left - 1
          end
        end
        if not any or left == 0 then break end
      end
      if room >= 0 and (left == 0 or room / left >= 1) then
        -- What the unfixed share; with none, what is over goes to all.
        local share = left > 0 and room / left or 0
        local spare = left > 0 and 0 or room / n
        local x = 0
        for i = 1, n do
          local w = (fixed[i] and need[i] or share) + spare
          local e = edges[i]
          e.left = math.floor(x + 0.5)
          e.right = math.floor(x + w + 0.5)
          e.width = e.right - e.left
          x = x + w + TAB_GAP
        end
      end
    end
    for i = 1, n do
      local plate, e = S.plates[TABS[i].key], edges[i]
      plate:ClearAllPoints()
      plate:SetPoint("TOPLEFT", plate:GetParent(), "TOPLEFT", EDGE + e.left, -TOP)
      plate:SetWidth(e.width)
      FitOne(plate)
    end
  end

  -- state: "on", "off", or nil for no square at all.
  function Tabs.SetSquare(key, state)
    local plate = S.plates[key]
    local sq = plate and plate.Square
    if not sq then return end
    if state == "on" then
      sq.Fill:SetColorTexture(0.38, 0.80, 0.44, 1)
      sq.Fill:Show()
      for i = 1, 4 do sq.Ring[i]:Hide() end
    elseif state == "off" then
      sq.Fill:Hide()
      for i = 1, 4 do sq.Ring[i]:Show() end
    end
    local want = state ~= nil
    if sq:IsShown() ~= want then
      sq:SetShown(want)
      FitOne(plate)
    end
  end

  function Tabs.Select(key)
    for i = 1, #TABS do
      local k = TABS[i].key
      S.pages[k]:SetShown(k == key)
      ns.Theme.SetPlateSelected(S.plates[k], k == key)
    end
  end
end

-------------------------------------------------------------
-- What a switch or a window changes elsewhere on the panel
-------------------------------------------------------------

-- The minimap icon's switch: its rows grey with it, its tab's square, the
-- icon on its stage.
function State.Minimap()
  local Icon = ns.MinimapButton
  local on = Icon and Icon.GetEnabled and Icon.GetEnabled() and true or false
  Rows.SetBlock(S.minimapBlock, on)
  State.MinimapRows()
  Tabs.SetSquare("minimap", on and "on" or "off")
  Ctx.Paint("minimap")
end

-- With the icon on, the rows that say how something looks grey while that
-- something is not there, each saying what turns it on (Rows.Why): Pulse
-- while Glow is off; Glow color while neither Glow nor Flash on new mail,
-- the two things that wear it, is on; Shape, Color, Anchor, Offset X and
-- Offset Y while Show marker is Off; Larger when alone unless Show marker
-- is Always (the one choice that puts the marker on its own). With the
-- icon off the block has them grey already, saying to turn the icon on.
function State.MinimapRows()
  local Icon, rows = ns.MinimapButton, S.mmRows
  if not (Icon and rows and Icon.GetEnabled and Icon.GetEnabled()) then return end
  local expiry = Icon.GetExpiry()
  local marking = expiry ~= "off"
  local glow = Icon.GetGlow() and true or false
  if rows.marker then Rows.SetEnabled(rows.marker, marking) end
  if rows.color then Rows.SetEnabled(rows.color, marking) end
  if rows.corner then Rows.SetEnabled(rows.corner, marking) end
  if rows.offx then Rows.SetEnabled(rows.offx, marking) end
  if rows.offy then Rows.SetEnabled(rows.offy, marking) end
  if rows.large then Rows.SetEnabled(rows.large, expiry == "always") end
  if rows.pulse then Rows.SetEnabled(rows.pulse, glow) end
  if rows.glow then Rows.SetEnabled(rows.glow, glow or (Icon.GetAlertFlash() and true or false)) end
end

-- Row layout stays live with Larger mail rows on: History, Mail Memory and
-- another character's box are one line whatever the Mail tab's rows are.
-- Its inspector then says the Mail tab's own rows are not among them.
function State.RowLayout()
  local cell = S.lanesCell
  if not cell then return end
  local larger = not ns.MailboxUI.GetOption("compactRows")
  cell.entry = (larger and cell.largeEntry or cell.plainEntry) or cell.entry
end

function State.Memory()
  local on = ns.MailboxUI.GetOption("mailMemory") and true or false
  Rows.SetBlock(S.memoryBlock, on)
  Tabs.SetSquare("memory", on and "on" or "off")
end

-- Who the window's look comes from. Re-derived on every open rather than
-- fixed at build: it describes the LIVE session -- who is painting right
-- now, not what is saved for the next one -- and EllesmereUI can be
-- published late by a load-on-demand addon, its skin claiming through a
-- deferred handshake.
--
-- The two descriptions take different numbers of arguments (the override
-- one names the host twice: once for the window, once for the minimap it
-- still follows) and ns.L formats through string.format WITHOUT a pcall,
-- so each is given exactly its own.
function State.Inheritance()
  local host = S.installedHost
  local entry = S.idle.window
  local title, text
  if not host then
    title, text = L["OPT_STYLE_TITLE"], L["OPT_STYLE_DESC"]
    if entry.title ~= title or entry.text ~= text then
      entry.title, entry.text = title, text
      S.textGen = S.textGen + 1
    end
    return
  end
  -- EllesmereUI on one of its stock looks, with the style left on
  -- EllesmereUI: its skin stood down so Postbox could wear its own Blizzard
  -- look beside Blizzard's windows. Still green -- the window is following
  -- the host, just not in the host's own paint -- and said in the host's
  -- own words for the look, so the player can find the switch.
  local eui = ns.SkinEllesmere
  local stock = eui and type(eui.GetStockLook) == "function" and eui.GetStockLook()
  local stockName = stock == "classic" and L["OPT_STYLE_LOOK_CLASSIC"]
    or stock == "blizzard" and L["OPT_STYLE_LOOK_BLIZZARD"] or nil
  if HostSkinName() then
    S.badgeGreen = true
    title = L("OPT_STYLE_INHERIT", host)
    text = L("OPT_STYLE_INHERIT_DESC", host)
  elseif stockName then
    S.badgeGreen = true
    title = L("OPT_STYLE_FOLLOW", host)
    text = L("OPT_STYLE_FOLLOW_DESC", host, stockName)
  else
    S.badgeGreen = false
    title = L("OPT_STYLE_OVERRIDE", host)
    text = L("OPT_STYLE_OVERRIDE_DESC", host, host)
  end
  if entry.title ~= title or entry.text ~= text then
    entry.title, entry.text = title, text
    S.textGen = S.textGen + 1
  end
end

-- The Postbox window's mark, where the window is on screen (at a mailbox,
-- or already up as the preview); nil otherwise, and arranging then opens
-- the window's preview (MailboxUI.OpenPreview).
function State.ArrangeToggle()
  local UI = ns.MailboxUI
  local window = UI and UI._frame
  if window and window:IsShown() and window.ArrangeButton then return window.ArrangeButton end
  return nil
end

-- The arrange button is always live: at a mailbox it arranges the Postbox
-- window, anywhere else that window's preview. Its mark takes the caption's
-- colour, read on every refresh, since the palette can change under the
-- open panel.
function State.Arrange(cell)
  cell = cell or S.arrangeCell
  if not cell then return end
  local btn = cell.button
  if btn.Mark then
    local c = ns.Theme.Colors.textPrimary
    Ctx.TintMark(btn.Mark, c[1], c[2], c[3], 1)
  end
end

-- The characters hidden from the character list (Core/MailMemory.lua, 2b):
-- who they are, and one button that shows them all again. The list's own
-- foot brings them back one at a time; this row is the way back that is
-- always here, even once nobody is left for that list to offer. The names,
-- and the lines the row's tooltip lists, are made here, on open, so a hover
-- only reads them.
function State.Hidden()
  local row = S.hiddenRow
  if not row then return end
  local Memory = ns.MailMemory
  local list = (Memory and type(Memory.HiddenCharacters) == "function") and Memory.HiddenCharacters() or {}
  local names, lines = {}, row.lines
  local named = Memory and Memory.ClassName
  for i = 1, #list do
    local who = list[i]
    names[i] = named and Memory.ClassName(who.realm, who.name) or who.name
  end
  for i = #lines, 1, -1 do lines[i] = nil end
  local shown = math.min(#names, 12)
  -- The tooltip's lines inked for the tooltip, which stays dark in Light
  -- mode; the row's for the row.
  for i = 1, shown do
    local who = list[i]
    lines[i] = named and Memory.ClassName(who.realm, who.name, nil, "tooltip") or who.name
  end
  row.moreLine = #names > shown and string.format(L["MEMORY_WAITING_MORE"], #names - shown) or nil
  row.any = #names > 0
  row.namesText = row.any and table.concat(names, ", ") or L["OPT_HIDDEN_NONE"]
  row.more:SetShown(row.any)
end

-- The names, right-aligned against the button: class colours, the realm
-- where it is not this one, cut short -- the whole list is on hover.
-- Measured on every open: a host skin re-fonts the button after build.
function State.FitHidden()
  local row = S.hiddenRow
  if not row then return end
  local T = ns.Theme
  T.SizeToText(row.more, { height = CHECK_H })
  row.Names:ClearAllPoints()
  if row.any then
    row.Names:SetPoint("RIGHT", row.more, "LEFT", -8, 0)
  else
    row.Names:SetPoint("RIGHT", row, "RIGHT", -CONTROL_R, 0)
  end
  T.FitText(row.Name, ROW_W - NAME_X - CONTROL_R, row.nameText, row)
  local room = ROW_W - NAME_X - CONTROL_R - TextW(row.Name) - NAME_GAP
    - (row.any and (math.ceil(row.more:GetWidth() or 0) + NAME_GAP) or 0)
  T.FitText(row.Names, math.max(room, 20), row.namesText or "")
end

-------------------------------------------------------------
-- The pages
--
-- Each tab's rows, in the order a player reads them. Every setting keeps
-- the saved path, the default and the effect it has always had; only where
-- it sits has changed.
-------------------------------------------------------------

-- The Mail tab: how a row looks, what stands under the list, how the tab
-- collects, and the sound when mail arrives -- which a player looks for
-- with the mail, not under the minimap.
function Pages.mail(col)
  -- A setting the drawing of the window shows: its text stands under the
  -- drawing, never over it (Layout), and while it is pointed at the drawing
  -- rings `part`, what it changes (MW.RingTarget).
  local function Shown(entry, part)
    entry.stage, entry.part = "mail", part
  end
  Rows.Group(col, L["OPT_ROWS_HEADING"])
  -- Which columns a row shows, in what order, and the gold's and the time
  -- left's own choices are arranged in the window itself, where the rows
  -- are (Core/Arrange.lua). This is the way in from here: the same one the
  -- mark beside the cog is, a row like the others with its button on the
  -- right. The inspector names what the row and its button do together,
  -- and that it works anywhere: away from a mailbox it opens the window's
  -- preview over sample mail. Arrange Postbox, since it arranges History
  -- and Mail Memory's window too: as wide as the dropdowns below it, and
  -- wider where a translation needs it. First, since it is where most of
  -- how a row looks is chosen.
  local arrange = Rows.Button(col, {
    title = L["OPT_ARRANGE_ROW"], text = L["ARRANGE_TIP"] .. "\n\n" .. L["OPT_ARRANGE_ANYWHERE"],
    caption = L["OPT_ARRANGE_CAPTION"], onClick = Panel.Arrange, onHover = State.Arrange, mark = true,
    minWidth = DD_W,
  })
  arrange.entry.title, arrange.entry.extra = L["OPT_ARRANGE_BUTTON"], "arrange"
  S.arrangeCell = arrange

  -- Row layout: every figure in its own column on every row (Columns), or
  -- each row closing its gaps away from the subject and giving it the room
  -- (Packed), in the Mail tab, History and Mail Memory alike. Every list's
  -- rows are placed again where they stand; the drawing's rows show the
  -- sales' gold move, and while the choice is pointed at, the drawing rings
  -- the gold and the slots. Under the way into arranging and over Larger
  -- mail rows: how a row's figures stand, then how tall the row is.
  local lanes = Rows.Dropdown(col, {
    title = L["OPT_ROW_LAYOUT_TITLE"], text = L["OPT_ROW_LAYOUT_DESC"],
    items = {
      { id = "columns", name = L["OPT_ROW_LAYOUT_COLUMNS"] },
      { id = "packed",  name = L["OPT_ROW_LAYOUT_PACKED"] },
    },
    get = function() return ns.MailboxUI.GetRowPacking and ns.MailboxUI.GetRowPacking() or "columns" end,
    set = function(id)
      if ns.MailboxUI.SetRowPacking then ns.MailboxUI.SetRowPacking(id) end
      local AR = ns.Arrange
      if AR and AR.RowsChanged then AR.RowsChanged(false) end
      Ctx.Repaint()
    end,
  })
  S.lanesCell = lanes
  -- While Larger mail rows are on, Row layout's inspector says which lists
  -- it still governs (State.RowLayout): a second entry, measured with the
  -- rest.
  lanes.plainEntry = lanes.entry
  lanes.largeEntry = Entry(L["OPT_ROW_LAYOUT_TITLE"], L["OPT_ROW_LAYOUT_DESC"] .. "\n\n" .. L["OPT_ROW_LAYOUT_LARGER"])
  Shown(lanes.plainEntry, "figures")
  Shown(lanes.largeEntry, "figures")

  -- Compact is the default, so the switch is the one a player turns ON to
  -- change it: larger, two-line rows. The stored option is still
  -- compactRows, read inverted, so nobody's choice moves.
  local larger = Rows.Check(col, {
    title = L["OPT_LARGER_ROWS_TITLE"], text = L["OPT_LARGER_ROWS_DESC"],
    get = function() return not ns.MailboxUI.GetOption("compactRows") end,
    set = function(on)
      ns.MailboxUI.SetOption("compactRows", not on)
      if ns.MailboxUI.RefreshCollectRowLayout then ns.MailboxUI.RefreshCollectRowLayout() end
    end,
    after = function()
      State.RowLayout()
      Ctx.Repaint()
    end,
  })
  Shown(larger.entry, "rows")

  -- The crafting quality mark, in the list, History and the memory alike,
  -- is two things a player sets apart: the badge on the corner of the
  -- item's icon (on by default), and a mark beside the name -- before it,
  -- with the names kept in line, after it as a chat link has it, or none
  -- (the default). Every list's rows are drawn again, and the drawing's,
  -- and the arrange mode's card where it shows the same choice.
  local function ArrangeFollows()
    local AR = ns.Arrange
    if AR and AR.ListWideChanged then AR.ListWideChanged() end
  end
  local function QualityChanged()
    if ns.MailboxUI.RefreshCollectRowLayout then ns.MailboxUI.RefreshCollectRowLayout() end
    if ns.MailMemory and ns.MailMemory.Refresh then ns.MailMemory.Refresh() end
    Ctx.Repaint()
    ArrangeFollows()
  end
  -- The badge shares its row with the stack count on the same icon (and the
  -- stack edge behind it, and an auction subject's count taken off the row):
  -- the Mail page is the panel's tallest, and a row of its own would make
  -- the whole panel taller. Either redraws the rows the same way. The count
  -- comes first, so the badge stands next to Quality by the name below it:
  -- the two quality choices together, side by side or, where the pair comes
  -- apart, one above the other.
  local marks = Rows.Pair(col, {
    title = L["OPT_ICON_COUNTS_TITLE"], text = L["OPT_ICON_COUNTS_DESC"],
    get = function() return ns.MailboxUI.GetOption("iconCounts") end,
    set = function(on)
      ns.MailboxUI.SetOption("iconCounts", on)
      QualityChanged()
    end,
  }, {
    title = L["OPT_QUALITY_ICON_TITLE"], text = L["OPT_QUALITY_ICON_DESC"],
    get = function() return not ns.MailboxUI.GetQualityIcon or ns.MailboxUI.GetQualityIcon() end,
    set = function(on)
      if ns.MailboxUI.SetQualityIcon then ns.MailboxUI.SetQualityIcon(on) end
      QualityChanged()
    end,
  })
  Shown(marks.pair[1].entry, "icons")
  Shown(marks.pair[2].entry, "mark")
  local byName = Rows.Dropdown(col, {
    title = L["OPT_QUALITY_NAME_TITLE"], text = L["OPT_QUALITY_NAME_DESC"],
    items = {
      { id = "before", name = L["OPT_QUALITY_NAME_BEFORE"] },
      { id = "after",  name = L["OPT_QUALITY_NAME_AFTER"] },
      { id = "off",    name = L["OPT_QUALITY_OFF"] },
    },
    get = function() return ns.MailboxUI.GetQualityName and ns.MailboxUI.GetQualityName() or "off" end,
    set = function(id)
      if ns.MailboxUI.SetQualityName then ns.MailboxUI.SetQualityName(id) end
      QualityChanged()
    end,
  })
  Shown(byName.entry, "name")
  -- What resting on the item icon of a mail with several items shows: the
  -- list of them, or the fan, the items spread beside the icon to take one
  -- at a time (CollectTab). Read on hover, so nothing is redrawn. The same
  -- choice is on the Icon's card while arranging. Its row is the one the
  -- category buttons and the totals gave up by sharing theirs, below.
  Rows.Dropdown(col, {
    title = L["OPT_ATTACH_HOVER_TITLE"], text = L["OPT_ATTACH_HOVER_DESC"],
    items = {
      { id = "tooltip", name = L["OPT_ATTACH_HOVER_TOOLTIP"] },
      { id = "fan",     name = L["OPT_ATTACH_HOVER_FAN"] },
    },
    get = function() return ns.MailboxUI.GetAttachHover and ns.MailboxUI.GetAttachHover() or "tooltip" end,
    set = function(id)
      if ns.MailboxUI.SetAttachHover then ns.MailboxUI.SetAttachHover(id) end
      ArrangeFollows()
    end,
  })

  -- What stands under the list: the category buttons and the totals, the
  -- two blocks the tab's foot holds, and the counts on Inbox and on those
  -- buttons.
  Rows.Group(col, L["ARRANGE_UNDER_LIST"])
  -- The totals band is a block under the list as the buttons are: the same
  -- refresh stacks the blocks again and moves the window's floor. The two
  -- share a row, as the blocks they switch share the foot of the tab: the
  -- Mail page is the panel's tallest, and Attachments on hover took the row.
  local blocks = Rows.Pair(col, {
    title = L["OPT_CATEGORY_BUTTONS_TITLE"], text = L["OPT_CATEGORY_BUTTONS_DESC"],
    get = function() return ns.MailboxUI.GetOption("showCategoryButtons") end,
    set = function(on)
      ns.MailboxUI.SetOption("showCategoryButtons", on)
      if ns.MailboxUI.RefreshCollectCategoryButtons then ns.MailboxUI.RefreshCollectCategoryButtons() end
      Ctx.Repaint()
    end,
  }, {
    title = L["OPT_TOTALS_TITLE"], text = L["OPT_TOTALS_DESC"],
    get = function() return ns.MailboxUI.GetOption("showTotals") end,
    set = function(on)
      ns.MailboxUI.SetOption("showTotals", on)
      if ns.MailboxUI.RefreshCollectCategoryButtons then ns.MailboxUI.RefreshCollectCategoryButtons() end
      Ctx.Repaint()
    end,
  })
  Shown(blocks.pair[1].entry, "grid")
  Shown(blocks.pair[2].entry, "band")
  local counts = Rows.Check(col, {
    title = L["OPT_TAB_COUNTS_TITLE"], text = L["OPT_TAB_COUNTS_DESC"],
    get = function() return ns.MailboxUI.GetOption("showTabCounts") end,
    set = function(on)
      ns.MailboxUI.SetOption("showTabCounts", on)
      if ns.MailboxUI.RefreshCollectTabCounts then ns.MailboxUI.RefreshCollectTabCounts() end
      -- Mail Memory's header counts its box under the same switch.
      if ns.MailMemory and ns.MailMemory.Refresh then ns.MailMemory.Refresh() end
      Ctx.Repaint()
    end,
  })
  Shown(counts.entry, "segs")
  -- What the window's Mail tab wears while mail is waiting, each choice a
  -- picture of the caption itself, in the client's language: the dot after
  -- the name (the default), before it, or the name alone. Its own setting,
  -- beside the counts but not under them.
  do
    local UI = ns.MailboxUI
    local function Caption(mode)
      if UI.TabCaption then return UI.TabCaption(mode, true) end
      return L["TAB_COLLECT"]
    end
    local tab = Rows.Dropdown(col, {
      title = L["OPT_TAB_INDICATOR_TITLE"], text = L["OPT_TAB_INDICATOR_DESC"],
      items = {
        { id = "dot",    name = Caption("dot") },
        { id = "before", name = Caption("before") },
        { id = "none",   name = Caption("none") },
      },
      get = function() return UI.GetTabIndicator and UI.GetTabIndicator() or "dot" end,
      set = function(id)
        if UI.SetTabIndicator then UI.SetTabIndicator(id) end
        Ctx.Repaint()
      end,
    })
    Shown(tab.entry, "tab")
  end

  Rows.Group(col, L["OPT_COLLECTING_HEADING"])
  -- Nothing to refresh: the mapping is read at the moment a row is clicked,
  -- and the row tooltip's hint line is composed on hover from the same
  -- reading. A list rebuild would repaint rows that are already correct.
  Rows.Check(col, {
    title = L["OPT_PREVIEW_CLICK_TITLE"], text = L["OPT_PREVIEW_CLICK_DESC"],
    get = function() return ns.MailboxUI.GetOption("previewOnClick") end,
    set = function(on) ns.MailboxUI.SetOption("previewOnClick", on) end,
  })
  -- How many bag slots a collect run leaves free: None (runs go until the
  -- bags are full) or 1 to 12, a mail's worth of items. Read at the start
  -- of each run.
  local freeItems = { { id = 0, name = L["OPT_KEEP_FREE_NONE"] } }
  for n = 1, (ns.MailboxUI.KEEP_FREE_MAX or 12) do
    freeItems[#freeItems + 1] = { id = n, name = ns.Plural("COUNT_SLOTS", n) }
  end
  Rows.Dropdown(col, {
    title = L["OPT_KEEP_FREE_TITLE"], text = L["OPT_KEEP_FREE_DESC"],
    items = freeItems,
    get = function() return ns.MailboxUI.GetKeepFreeSlots and ns.MailboxUI.GetKeepFreeSlots() or 0 end,
    set = function(id) if ns.MailboxUI.SetKeepFreeSlots then ns.MailboxUI.SetKeepFreeSlots(id) end end,
  })
  -- Read mail with nothing left: under a divider after the inbox, in a Done
  -- tab of its own, or deleted once finished with. One choice, three
  -- answers -- a switch for the tab and another for deleting would have
  -- been two controls over one fact.
  local read = Rows.Dropdown(col, {
    title = L["OPT_READ_MAIL_TITLE"], text = L["OPT_READ_MAIL_DESC"],
    items = {
      { id = "fold",   name = L["OPT_READ_FOLD"] },
      { id = "tab",    name = L["OPT_READ_TAB"] },
      { id = "delete", name = L["OPT_READ_DELETE"] },
    },
    get = function() return ns.MailboxUI.GetReadMode and ns.MailboxUI.GetReadMode() or "fold" end,
    set = function(id)
      if ns.MailboxUI.SetReadMode then ns.MailboxUI.SetReadMode(id) end
      Ctx.Repaint()
    end,
  })
  Shown(read.entry, "read")
  -- How far back History goes, or Never, which turns it off (stored as 0),
  -- last: it clears what History kept on every character, so it is asked
  -- first, and until the answer the choice shows what it was. Cancel leaves
  -- it there. Where the client has no popup, it is set as it was before.
  local dayItems = {}
  for _, days in ipairs({ 7, 14, 21, 30 }) do
    dayItems[#dayItems + 1] = { id = days, name = ns.Plural("OPT_HISTORY_DAYS", days) }
  end
  dayItems[#dayItems + 1] = { id = 0, name = L["OPT_HISTORY_NEVER"] }
  local POPUP_HISTORY_OFF = "POSTBOX_HISTORY_OFF"
  local keep
  keep = Rows.Dropdown(col, {
    title = L["OPT_HISTORY_KEEP_TITLE"], text = L["OPT_HISTORY_KEEP_DESC"],
    items = dayItems,
    get = function() return ns.MailboxUI.GetHistoryDays and ns.MailboxUI.GetHistoryDays() or 7 end,
    set = function(id)
      local UI = ns.MailboxUI
      if not UI.SetHistoryDays then return end
      local asks = type(StaticPopupDialogs) == "table" and type(StaticPopup_Show) == "function"
      if id ~= 0 or not asks or (UI.GetHistoryDays and UI.GetHistoryDays() == 0) then
        UI.SetHistoryDays(id)
        return
      end
      Rows.PaintDropdown(keep)
      if not StaticPopupDialogs[POPUP_HISTORY_OFF] then
        StaticPopupDialogs[POPUP_HISTORY_OFF] = {
          text = "%s",
          button1 = L["BTN_HISTORY_OFF"],
          button2 = L["COD_CONFIRM_CANCEL"],
          OnAccept = function()
            if ns.MailboxUI.SetHistoryDays then ns.MailboxUI.SetHistoryDays(0) end
            Panel.RefreshControls()
          end,
          timeout = 0,
          whileDead = true,
          hideOnEscape = true,
          showAlert = true,
        }
      end
      ns.Theme.LiftPopup(StaticPopup_Show(POPUP_HISTORY_OFF, L["MSG_HISTORY_OFF_CONFIRM"]))
    end,
  })

  -- The sound when mail arrives while you are out in the world. The flash
  -- stays with the minimap icon: it is drawn on the icon.
  Rows.Group(col, L["OPT_ALERTS_HEADING"])
  Rows.Check(col, {
    title = L["OPT_ALERT_SOUND_TITLE"], text = L["OPT_ALERT_SOUND_DESC"],
    get = function() return ns.MinimapButton and ns.MinimapButton.GetAlertSound() end,
    set = function(on) if ns.MinimapButton then ns.MinimapButton.SetAlertSound(on) end end,
  })
end

-- The Send tab: the settings about composing, the form's own first, then
-- the one that reaches it from the Mail tab. The address book they draw on
-- is the tile at the top of the inspector; /postbox recipients is the other
-- way in.
function Pages.send(col)
  -- What a sent mail leaves in the form: nothing, the recipient, or the
  -- recipient and the subject. Nothing to refresh: it is read at the moment
  -- a send succeeds.
  Rows.Dropdown(col, {
    title = L["OPT_AFTER_SEND_TITLE"], text = L["OPT_AFTER_SEND_DESC"],
    items = {
      { id = "nothing",   name = L["OPT_AFTER_SEND_NOTHING"] },
      { id = "recipient", name = L["OPT_AFTER_SEND_RECIPIENT"] },
      { id = "subject",   name = L["OPT_AFTER_SEND_SUBJECT"] },
    },
    get = function() return ns.MailboxUI.GetAfterSendKeep and ns.MailboxUI.GetAfterSendKeep() or "nothing" end,
    set = function(id) if ns.MailboxUI.SetAfterSendKeep then ns.MailboxUI.SetAfterSendKeep(id) end end,
  })
  -- Ctrl+Enter in the draft's fields, named in the client's own words for
  -- the keys, as the Send button's hint names them (SendTab, 8b).
  local keys = (ns.SendTab and ns.SendTab.SendKeys) and ns.SendTab.SendKeys() or "Ctrl+Enter"
  Rows.Check(col, {
    title = L("OPT_CTRL_ENTER_TITLE", keys), text = L("OPT_CTRL_ENTER_DESC", keys),
    get = function() return ns.MailboxUI.GetOption("ctrlEnterSends") end,
    set = function(on)
      ns.MailboxUI.SetOption("ctrlEnterSends", on)
      if ns.SendTab and ns.SendTab.RefreshSendHint then ns.SendTab.RefreshSendHint() end
    end,
  })
  Rows.Check(col, {
    title = L["OPT_ATTACH_MAIL_TITLE"], text = L["OPT_ATTACH_MAIL_DESC"],
    get = function() return ns.MailboxUI.GetOption("attachFromMail") end,
    set = function(on)
      ns.MailboxUI.SetOption("attachFromMail", on)
      -- Applies to the mailbox that is open right now, not the next one.
      if ns.MailboxUI.RefreshMailTabAttach then ns.MailboxUI.RefreshMailTabAttach() end
    end,
  })
end

-- The Window tab: the style first, since every row under it is that style's,
-- then the window's scale and where it opens -- under no heading, in every
-- style: the tab's name says what they are about. Then the style's own rows:
-- under the Postbox style in its groups (Colors, Edges and rows, Text:
-- .dev/design/postbox-style, spec section 3.1), under a creative style in
-- its two, under a host the opacity and the border.
function Pages.window(col)
  local Skin = GetSkin()
  local own = Skin and Skin.IsPostboxStyle and true or false

  -- The style choice. A host UI is offered first and is the default
  -- wherever one is installed, so the familiar answer is the one already
  -- selected -- but it is now an answer rather than a foregone conclusion.
  local host = S.installedHost
  local styleItems = {}
  if host then styleItems[#styleItems + 1] = { id = "host", name = host } end
  styleItems[#styleItems + 1] = { id = "blizzard", name = L["OPT_STYLE_BLIZZARD"] }
  styleItems[#styleItems + 1] = { id = "postbox",  name = L["OPT_STYLE_POSTBOX"] }
  -- The creative styles (Core/Skin_Creative.lua), after Postbox's own.
  local creative = ns.CreativeStyles
  if creative and type(creative.Choices) == "function" then
    local extra = creative.Choices()
    for i = 1, #extra do styleItems[#styleItems + 1] = extra[i] end
  end
  S.styleCell = Rows.Dropdown(col, {
    title = L["OPT_STYLE_TITLE"], text = L["OPT_STYLE_DESC"], items = styleItems,
    get = function() return ns.MailboxUI.GetStyleChoice and ns.MailboxUI.GetStyleChoice() end,
    set = function(id)
      if ns.MailboxUI.SetStyleChoice then ns.MailboxUI.SetStyleChoice(id) end
      -- The style is claimed once at login, so the choice needs a reload
      -- to take. A dialog with the reload in it beats a chat line telling
      -- the player to go and type one -- and Later is a real answer: the
      -- setting is already saved either way.
      OfferStyleReload()
    end,
  })

  -- The window scale, in every style: every Postbox window, live, each kept
  -- where it stands (MailboxUI.SetWindowScale).
  local scaleItems = {}
  for pct = 80, 130, 5 do
    scaleItems[#scaleItems + 1] = { id = pct, name = string.format(L["OPT_BG_OPACITY_STEP"], pct) }
  end
  Rows.Dropdown(col, {
    title = L["OPT_SCALE_TITLE"], text = L["OPT_SCALE_DESC"], items = scaleItems,
    get = function()
      local s = ns.MailboxUI.GetWindowScale and ns.MailboxUI.GetWindowScale() or 1
      return math.floor(s * 20 + 0.5) * 5
    end,
    set = function(id)
      if ns.MailboxUI.SetWindowScale then ns.MailboxUI.SetWindowScale((tonumber(id) or 100) / 100) end
      Ctx.Repaint()
    end,
  })

  Rows.Check(col, {
    title = L["GRID_TOGGLE_TITLE"], text = L["GRID_TOGGLE_DESC"],
    get = function() return ns.MailboxUI.GetOption("gridDock") end,
    set = function(on)
      ns.MailboxUI.SetOption("gridDock", on)
      if on and ns.MailboxUI._state then ns.MailboxUI._state.freeMoved = false end
      if ns.MailboxUI.ApplyWindowLayout then ns.MailboxUI.ApplyWindowLayout() end
    end,
  })

  -- The chosen style's own controls. Whichever skin claimed the window
  -- answers these; the panel does not know or care which one it is
  -- talking to. A style that publishes no such controls (Blizzard) simply
  -- contributes nothing here.
  if not Skin then return end
  if Skin.IsCreativeStyle and Pages.windowCreative then
    Pages.windowCreative(col, Skin)
    return
  end
  if own then
    Pages.windowPostbox(col, Skin)
    return
  end
  -- "Leave it alone" means different things to different styles: under a
  -- host it means match that UI, and under Postbox's own it means the
  -- value the skin was authored with.
  local autoName = HostSkinName() and L("OPT_APPEARANCE_MATCH", HostSkinName()) or L["OPT_APPEARANCE_DEFAULT"]
  -- The opacity, the border, and the border's size last: the one row that
  -- stands aside (State.BorderSize) moves nothing when it does.
  local opacityItems = { { id = "auto", name = autoName } }
  for _, pct in ipairs({ 100, 95, 90, 85, 80, 75, 70, 60, 50, 40, 25, 0 }) do
    opacityItems[#opacityItems + 1] = { id = pct, name = string.format(L["OPT_BG_OPACITY_STEP"], pct) }
  end
  Rows.Dropdown(col, {
    title = L["OPT_BG_OPACITY_TITLE"], text = L["OPT_BG_OPACITY_DESC"], items = opacityItems,
    get = function()
      if Skin.IsBgOpacityDefault and Skin.IsBgOpacityDefault() then return "auto" end
      return math.floor(Skin.GetBgOpacity() * 100 + 0.5)
    end,
    set = function(id)
      if id == "auto" then Skin.ResetBgOpacity()
      else Skin.SetBgOpacity((tonumber(id) or 100) / 100) end
      Ctx.Repaint()
    end,
  })

  -- The border row offers that entry where the skin has an edge to match:
  -- under EllesmereUI, "Match EllesmereUI", the edge the windows beside
  -- Postbox have (Core/Skin_EllesmereUI.lua), and an unset border is it. The
  -- size row never does: a size is a step of the chosen style, and Match has
  -- none of its own.
  local borderAuto = true
  if type(Skin.OffersBorderDefault) == "function" then
    borderAuto = Skin.OffersBorderDefault() and true or false
  end

  local borderItems = {}
  if borderAuto then borderItems[1] = { id = "auto", name = autoName } end
  for _, choice in ipairs(Skin.GetBorderChoices()) do
    borderItems[#borderItems + 1] = { id = choice.key, name = choice.name }
  end
  Rows.Dropdown(col, {
    title = L["OPT_BORDER_TITLE"],
    text = (borderAuto and HostSkinName()) and L("OPT_BORDER_DESC_MATCH", HostSkinName()) or L["OPT_BORDER_DESC"],
    items = borderItems,
    get = function()
      if borderAuto and Skin.IsBorderDefault and Skin.IsBorderDefault() then return "auto" end
      return Skin.GetBorderStyle()
    end,
    set = function(id)
      if id == "auto" then Skin.ResetBorder() else Skin.SetBorderStyle(id) end
      -- A pick sets the style's own size: the size row shows it, if it shows.
      State.BorderSize()
      Rows.PaintDropdown(S.borderSize.row)
      Ctx.Repaint()
    end,
  })

  -- Border size stands aside while the border has no size (None, Match).
  local sizeItems = {}
  for step = 1, 4 do
    sizeItems[#sizeItems + 1] = { id = step, name = string.format(L["OPT_BORDER_SIZE_STEP"], step) }
  end
  S.borderSize = {
    row = Rows.Dropdown(col, {
      title = L["OPT_BORDER_SIZE_TITLE"], text = L["OPT_BORDER_SIZE_DESC"], items = sizeItems,
      get = function() return Skin.GetBorderSize() end,
      set = function(id)
        Skin.SetBorderSize(id)
        Ctx.Repaint()
      end,
    }),
  }
  S.refresh[#S.refresh + 1] = State.BorderSize
end

-- Border size shown only while the chosen border has a size (the skin's
-- BorderHasSize; a skin without that answer keeps the row). It is the page's
-- last row, so hiding it moves nothing; the page keeps its height, as every
-- page does, the tallest page setting the list's. Run on every open and
-- after a border pick, so it is live.
function State.BorderSize()
  local b = S.borderSize
  if not b then return end
  local skin = GetSkin()
  local sized = true
  if skin and type(skin.BorderHasSize) == "function" then
    sized = skin.BorderHasSize() and true or false
  end
  if b.shown == sized then return end
  b.shown = sized
  b.row:SetShown(sized)
end

-- The Postbox style's own rows, in its groups (spec section 3.1): Colors
-- (Mode, the accent, the background colour -- the Mode's own list, a tint
-- among it -- and opacity), Edges and rows (the border, its colour, the
-- corners, row stripes and the sheen side by side), Text (font, size,
-- outline; every text's colour is worked out from what it stands on, so
-- there is none to pick). The drawing at the
-- top of the inspector is the style's window, small, painted live from every
-- one of them; the accent's row adds its measured contrast under its
-- description.
do
  -- choices -> dropdown items.
  local function Items(list)
    local items = {}
    for i = 1, #list do items[i] = { id = list[i].key, name = list[i].name } end
    return items
  end

  -- choices -> id -> the colour its square shows. Custom reads the colour
  -- saved for it, at each paint.
  local function Swatches(list, kind, Skin)
    local map = {}
    for i = 1, #list do
      local c = list[i].swatch
      if c then map[list[i].key] = c end
    end
    return function(id)
      if id == "custom" then
        if Skin.GetCustomColor then return Skin.GetCustomColor(kind) end
        return nil
      end
      if id == "accent" and kind == "border" then return ns.Theme.GetAccentTone("mark") end
      local c = map[id]
      if c then return c[1], c[2], c[3] end
      return nil
    end
  end

  -- Custom is offered where the client has its colour picker.
  local function WithoutCustom(list, Skin)
    if Skin.CanPickColor and Skin.CanPickColor() then return list end
    local out = {}
    for i = 1, #list do if list[i].key ~= "custom" then out[#out + 1] = list[i] end end
    return out
  end

  local function Percent(values)
    local items = {}
    for i = 1, #values do items[i] = { id = values[i], name = string.format(L["OPT_BG_OPACITY_STEP"], values[i]) } end
    return items
  end

  function Pages.windowPostbox(col, Skin)
    Rows.Group(col, L["OPT_GROUP_COLORS"])
    Rows.Dropdown(col, {
      title = L["OPT_MODE_TITLE"], text = L["OPT_MODE_DESC"], items = Items(Skin.GetModeChoices()),
      get = function() return Skin.GetMode() end,
      set = function(id)
        Skin.SetMode(id)
        State.Postbox()
        Ctx.Repaint()
      end,
    })
    local accents = WithoutCustom(Skin.GetAccentChoices(), Skin)
    local accentRow = Rows.Dropdown(col, {
      title = L["OPT_ACCENT_TITLE"], text = L["OPT_ACCENT_DESC"], items = Items(accents),
      swatchFor = Swatches(accents, "accent", Skin),
      get = function() return Skin.GetAccentKey() end,
      set = function(id)
        if id == "custom" then Skin.PickColor("accent") else Skin.SetAccent(id) end
        Ctx.Repaint()
      end,
    })
    accentRow.entry.extra = "pbAccent"
    -- The background colour: the Mode's own list, each item kept for its
    -- Mode (State.Postbox hands the select the list of the Mode in force).
    -- Each square is the colour as it paints, read at each paint: a tint
    -- follows the accent and the class colour.
    S.pbSurfaceItems = {
      dark = Items(WithoutCustom(Skin.GetSurfaceChoices("dark"), Skin)),
      light = Items(WithoutCustom(Skin.GetSurfaceChoices("light"), Skin)),
    }
    S.pbSurfaceCell = Rows.Dropdown(col, {
      title = L["OPT_SURFACE_TITLE"], text = L["OPT_SURFACE_DESC"],
      items = S.pbSurfaceItems[Skin.GetMode()] or S.pbSurfaceItems.dark,
      swatchFor = function(id)
        if id == "custom" then return Skin.GetCustomColor("surface") end
        if Skin.SurfaceColor then return Skin.SurfaceColor(id) end
        return nil
      end,
      get = function() return Skin.GetSurfaceKey() end,
      set = function(id)
        if id == "custom" then Skin.PickColor("surface") else Skin.SetSurface(id) end
        Ctx.Repaint()
      end,
    })
    Rows.Dropdown(col, {
      title = L["OPT_BG_OPACITY_TITLE"], text = L["OPT_BG_OPACITY_DESC_POSTBOX"],
      items = Percent({ 100, 95, 90, 85, 80, 75, 70, 60, 50, 40, 25, 0 }),
      get = function() return math.floor(Skin.GetBgOpacity() * 100 + 0.5) end,
      set = function(id)
        Skin.SetBgOpacity((tonumber(id) or 100) / 100)
        Rows.PaintDropdown(S.pbOpacityCell)
        Ctx.Repaint()
      end,
    })
    S.pbOpacityCell = S.cells[#S.cells]

    Rows.Group(col, L["OPT_GROUP_EDGES"])
    Rows.Dropdown(col, {
      title = L["OPT_BORDER_TITLE"], text = L["OPT_BORDER_DESC_POSTBOX"], items = Items(Skin.GetBorderChoices()),
      get = function() return Skin.GetBorderStyle() end,
      set = function(id)
        Skin.SetBorderStyle(id)
        Ctx.Repaint()
      end,
    })
    local tones = WithoutCustom(Skin.GetBorderToneChoices(), Skin)
    Rows.Dropdown(col, {
      title = L["OPT_BORDER_COLOR_TITLE"], text = L["OPT_BORDER_COLOR_DESC"], items = Items(tones),
      -- The greys' squares are the palette's own, read at each paint: a
      -- light window's gray is lighter.
      swatchFor = function(id)
        if id == "custom" then return Skin.GetCustomColor("border") end
        if id == "accent" then return ns.Theme.GetAccentTone("mark") end
        local c = Skin.Palette.borderTone[id]
        if c then return c[1], c[2], c[3] end
        return nil
      end,
      get = function() return Skin.GetBorderTone() end,
      set = function(id)
        if id == "custom" then Skin.PickColor("border") else Skin.SetBorderTone(id) end
        Ctx.Repaint()
      end,
    })
    Rows.Dropdown(col, {
      title = L["OPT_CORNERS_TITLE"], text = L["OPT_CORNERS_DESC"], items = Items(Skin.GetCornerChoices()),
      get = function() return Skin.GetCorners() end,
      set = function(id)
        Skin.SetCorners(id)
        Ctx.Repaint()
      end,
    })
    Rows.Pair(col, {
      title = L["OPT_STRIPES_TITLE"], text = L["OPT_STRIPES_DESC"],
      get = function() return Skin.GetRowStripes() end,
      set = function(on) Skin.SetRowStripes(on) Ctx.Repaint() end,
    }, {
      title = L["OPT_SHEEN_TITLE"], text = L["OPT_SHEEN_DESC"],
      get = function() return Skin.GetSheen() end,
      set = function(on) Skin.SetSheen(on) Ctx.Repaint() end,
    })

    Rows.Group(col, L["OPT_GROUP_TEXT"])
    Rows.Dropdown(col, {
      title = L["OPT_FONT_TITLE"], text = L["OPT_FONT_DESC"], items = Items(Skin.GetFontChoices()),
      get = function() return Skin.GetFont() end,
      set = function(id) Skin.SetFont(id) end,
    })
    local sizeItems = {}
    for _, scale in ipairs(Skin.GetTextScaleChoices()) do
      local pct = math.floor(scale * 100 + 0.5)
      sizeItems[#sizeItems + 1] = { id = pct, name = string.format(L["OPT_BG_OPACITY_STEP"], pct) }
    end
    Rows.Dropdown(col, {
      title = L["OPT_TEXT_SIZE_TITLE"], text = L["OPT_TEXT_SIZE_DESC"], items = sizeItems,
      get = function() return math.floor(Skin.GetTextScale() * 100 + 0.5) end,
      set = function(id) Skin.SetTextScale((tonumber(id) or 100) / 100) end,
    })
    S.pbOutlineCell = Rows.Dropdown(col, {
      title = L["OPT_OUTLINE_TITLE"], text = L["OPT_OUTLINE_DESC"], items = Items(Skin.GetOutlineChoices()),
      get = function() return Skin.GetOutline() end,
      set = function(id) Skin.SetOutline(id) Ctx.Repaint() end,
    })
    S.pbOutlineOn = true
  end
end

-- Under the Postbox style: the background colour's list is the Mode's, and
-- shows the Mode's own pick (a flip of the Mode changes the list live); the
-- opacity row shows the value in force (Light keeps 85% or more); and Text
-- outline stands aside while the Mode is Light, whose text is always drawn
-- clean, and comes back with Dark showing Dark's choice, which it keeps. It
-- is the page's last row, so hiding it moves nothing (State.BorderSize's
-- rule).
function State.Postbox()
  local cell = S.pbSurfaceCell
  local skin = GetSkin()
  if not (cell and skin and skin.GetMode) then return end
  local items = S.pbSurfaceItems and S.pbSurfaceItems[skin.GetMode()]
  if items and cell.items ~= items then
    cell.items = items
    if cell.dd.SetItems then cell.dd:SetItems(items) end
  end
  Rows.PaintDropdown(cell)
  if S.pbOpacityCell then Rows.PaintDropdown(S.pbOpacityCell) end
  local outline = S.pbOutlineCell
  local on = skin.GetMode() ~= "light"
  if outline and S.pbOutlineOn ~= on then
    S.pbOutlineOn = on
    outline:SetShown(on)
  end
end

-- A creative window style's rows (Core/Skin_Creative.lua): its colour choice
-- where it has one (the post box's paint), the opacity of the inside (its
-- frame stays solid) and the row stripes, then the font, text size and
-- outline, which it shares with the Postbox style. No border rows: the
-- style's rim is the window's edge.
function Pages.windowCreative(col, Skin)
  local CS = ns.CreativeStyles
  local def = CS and CS.Active and CS.Active()
  Rows.Group(col, L["OPT_GROUP_COLORS"])
  local variants = CS and CS.VariantChoices and CS.VariantChoices()
  if def and variants then
    Rows.Dropdown(col, {
      title = L[def.variantTitleKey], text = L[def.variantDescKey], items = variants,
      get = function() return CS.GetVariant() end,
      set = function(id)
        CS.SetVariant(id)
        Ctx.Repaint()
      end,
    })
  end
  -- A style on a light ground holds its inside at the Light floor (85%), so
  -- it offers only the steps it can show: a lower pick would snap back.
  local minPct = 0
  if type(Skin.GetMode) == "function" and Skin.GetMode() == "light" then
    minPct = math.floor((tonumber(Skin.LIGHT_OPACITY_FLOOR) or 0) * 100 + 0.5)
  end
  local opacityItems = {}
  for _, pct in ipairs({ 100, 95, 90, 85, 80, 75, 70, 60, 50, 40, 25, 0 }) do
    if pct >= minPct then
      opacityItems[#opacityItems + 1] = { id = pct, name = string.format(L["OPT_BG_OPACITY_STEP"], pct) }
    end
  end
  Rows.Dropdown(col, {
    title = L["OPT_BG_OPACITY_TITLE"], text = L["OPT_BG_OPACITY_DESC"], items = opacityItems,
    get = function() return math.floor(Skin.GetBgOpacity() * 100 + 0.5) end,
    set = function(id)
      Skin.SetBgOpacity((tonumber(id) or 100) / 100)
      Ctx.Repaint()
    end,
  })
  -- The row stripes apply here as under the Postbox style: its rows, a
  -- shade apart, with the window's other colours.
  if Skin.GetRowStripes then
    Rows.Check(col, {
      title = L["OPT_STRIPES_TITLE"], text = L["OPT_STRIPES_DESC"],
      get = function() return Skin.GetRowStripes() end,
      set = function(on) Skin.SetRowStripes(on) Ctx.Repaint() end,
    })
  end

  Rows.Group(col, L["OPT_GROUP_TEXT"])
  local fontItems = {}
  for _, choice in ipairs(Skin.GetFontChoices()) do
    fontItems[#fontItems + 1] = { id = choice.key, name = choice.name }
  end
  Rows.Dropdown(col, {
    title = L["OPT_FONT_TITLE"], text = L["OPT_FONT_DESC"], items = fontItems,
    get = function() return Skin.GetFont() end,
    set = function(id) Skin.SetFont(id) end,
  })
  local sizeItems = {}
  for _, scale in ipairs(Skin.GetTextScaleChoices()) do
    local pct = math.floor(scale * 100 + 0.5)
    sizeItems[#sizeItems + 1] = { id = pct, name = string.format(L["OPT_BG_OPACITY_STEP"], pct) }
  end
  Rows.Dropdown(col, {
    title = L["OPT_TEXT_SIZE_TITLE"], text = L["OPT_TEXT_SIZE_DESC"], items = sizeItems,
    get = function() return math.floor(Skin.GetTextScale() * 100 + 0.5) end,
    set = function(id) Skin.SetTextScale((tonumber(id) or 100) / 100) end,
  })
  -- The text outline applies here as under the Postbox style: the text is
  -- its fonts'. The rest of its rows (mode, accent, background colour,
  -- tint, border colour, corners, sheen, button text) are the Postbox
  -- style's own, and a creative style has its own art, accent and captions
  -- in their place.
  if Skin.GetOutlineChoices then
    local outlineItems = {}
    for _, choice in ipairs(Skin.GetOutlineChoices()) do
      outlineItems[#outlineItems + 1] = { id = choice.key, name = choice.name }
    end
    Rows.Dropdown(col, {
      title = L["OPT_OUTLINE_TITLE"], text = L["OPT_OUTLINE_DESC"], items = outlineItems,
      get = function() return Skin.GetOutline() end,
      set = function(id) Skin.SetOutline(id) Ctx.Repaint() end,
    })
  end
end

-- The Minimap tab (Core/MinimapButton.lua): the switch, then five groups --
-- when the icon shows, the icon itself, its glow, the marker for expiring
-- mail, and where it sits. Resolved at click time like every other
-- binding, so the page stays honest if the module is absent. A row grey
-- because another setting is off says what turns it on (Rows.Why); with
-- the switch off, every row says to turn the icon on.
function Pages.minimap(col)
  local Icon = ns.MinimapButton
  -- With EllesmereUI's minimap module running, Postbox restyles its own
  -- mail icon in place rather than drawing a second one; position and size
  -- are then EllesmereUI's to control, so those rows would be dead weight
  -- and are left out (see Core/MinimapButton.lua section 3).
  local hostStyled = Icon and Icon.IsHostStyled and Icon.IsHostStyled()
  local desc = hostStyled and L["OPT_MINIMAP_DESC_EUI"] or L["OPT_MINIMAP_DESC"]
  S.idle.minimap.text = desc

  Rows.Check(col, {
    master = true, title = L["OPT_MINIMAP_TITLE"], text = desc,
    get = function() return ns.MinimapButton and ns.MinimapButton.GetEnabled() end,
    set = function(on) if ns.MinimapButton then ns.MinimapButton.SetEnabled(on) end end,
    after = State.Minimap,
  })

  local block = Rows.Block(col, "OPT_MINIMAP_WHY_SWITCH")
  S.minimapBlock = block
  -- The settings with choices the drawing answers while pointed at
  -- (Ctx.MinimapMode), their text standing under it (Layout); and the rows
  -- that grey with another setting (State.MinimapRows).
  local modes, rows = {}, {}
  S.mmModes, S.mmRows = modes, rows

  local function Effect(titleKey, descKey, get, set, after)
    return {
      title = L[titleKey], text = L[descKey],
      get = function() return ns.MinimapButton and ns.MinimapButton[get]() end,
      set = function(on) if ns.MinimapButton then ns.MinimapButton[set](on) end end,
      after = after or Ctx.Repaint,
    }
  end

  -- When it shows: whether the icon is on the map at all. Under
  -- EllesmereUI's minimap too -- Postbox keeps their button shown for as
  -- long as this says (Core/MinimapButton.lua, SyncEuiButtonShown).
  Rows.Group(block, L["OPT_MINIMAP_GROUP_SHOWS"])
  local showNames = {
    new = L["OPT_MINIMAP_SHOW_NEW"], any = L["OPT_MINIMAP_SHOW_ANY"], always = L["OPT_MINIMAP_SHOW_ALWAYS"],
  }
  local showItems = {}
  for _, mode in ipairs((Icon and Icon.SHOW_MODES) or { "new" }) do
    showItems[#showItems + 1] = { id = mode, name = showNames[mode] }
  end
  local showRow = Rows.Dropdown(block, {
    title = L["OPT_MINIMAP_SHOW_TITLE"], text = L["OPT_MINIMAP_SHOW_DESC"], items = showItems,
    get = function() return ns.MinimapButton and ns.MinimapButton.GetShowWhen() end,
    set = function(id)
      if ns.MinimapButton then ns.MinimapButton.SetShowWhen(id) end
      Ctx.Repaint()
    end,
  })
  modes[showRow.entry] = "show"

  -- Icon: its art, its size, its count and its shadow. EllesmereUI's
  -- button wears all of it but the size.
  Rows.Group(block, L["OPT_MINIMAP_GROUP_ICON"])

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
  }
  -- Every item carries its art, so the open list shows the icons themselves
  -- -- the only way to browse them without pending mail.
  if Icon and Icon.GetIconSpec then
    for _, item in ipairs(iconItems) do item.icon = Icon.GetIconSpec(item.id) end
  end
  Rows.Dropdown(block, {
    title = L["OPT_MINIMAP_ICON_TITLE"], text = L["OPT_MINIMAP_ICON_DESC"], items = iconItems,
    get = function() return ns.MinimapButton and ns.MinimapButton.GetIcon() end,
    set = function(id)
      if ns.MinimapButton then ns.MinimapButton.SetIcon(id) end
      Ctx.Repaint()
    end,
  })

  if not hostStyled then
    -- 16 to 40 in steps of four, from the module, which also refuses any other.
    local sizeItems = {}
    for _, px in ipairs((Icon and Icon.ICON_SIZES) or { 16, 20, 24, 28 }) do
      sizeItems[#sizeItems + 1] = { id = px, name = string.format(L["OPT_MINIMAP_SIZE_STEP"], px) }
    end
    Rows.Dropdown(block, {
      title = L["OPT_MINIMAP_SIZE_TITLE"], text = L["OPT_MINIMAP_SIZE_DESC"], items = sizeItems,
      get = function() return ns.MinimapButton and ns.MinimapButton.GetIconSize() end,
      set = function(id)
        if ns.MinimapButton then ns.MinimapButton.SetIconSize(id) end
        Ctx.Repaint()
      end,
    })
  end

  -- The number on it. EllesmereUI's button carries it too.
  local countNames = {
    off = L["OPT_MINIMAP_COUNT_OFF"], me = L["OPT_MINIMAP_COUNT_ME"], all = L["OPT_MINIMAP_COUNT_ALL"],
  }
  local countItems = {}
  for _, mode in ipairs((Icon and Icon.COUNT_MODES) or { "off" }) do
    countItems[#countItems + 1] = { id = mode, name = countNames[mode] }
  end
  Rows.Dropdown(block, {
    title = L["OPT_MINIMAP_COUNT_TITLE"], text = L["OPT_MINIMAP_COUNT_DESC"], items = countItems,
    get = function() return ns.MinimapButton and ns.MinimapButton.GetCount() end,
    set = function(id)
      if ns.MinimapButton then ns.MinimapButton.SetCount(id) end
      Ctx.Repaint()
    end,
  })
  Rows.Check(block, Effect("OPT_MINIMAP_SHADOW_TITLE", "OPT_MINIMAP_SHADOW_DESC", "GetShadow", "SetShadow"))

  -- Glow: the glow and its pulse side by side, the one breathing the
  -- other; the colour it wears; and the flash when mail arrives, in that
  -- colour too. Pulse greys while Glow is off, Glow color while neither
  -- Glow nor the flash is on (State.MinimapRows).
  Rows.Group(block, L["OPT_MINIMAP_GROUP_GLOW"])
  local glowPair = Rows.Pair(block,
    Effect("OPT_MINIMAP_GLOW_TITLE", "OPT_MINIMAP_GLOW_DESC", "GetGlow", "SetGlow", function()
      State.MinimapRows()
      Ctx.Repaint()
    end),
    Effect("OPT_MINIMAP_PULSE_TITLE", "OPT_MINIMAP_PULSE_DESC", "GetPulse", "SetPulse"))
  rows.pulse = glowPair.pair[2]
  Rows.Why(rows.pulse, "OPT_MINIMAP_WHY_GLOW")

  -- A colour's list, Glow color's and the marker's Color alike: each choice
  -- carries its colour in the list; Custom, offered where the client has
  -- its colour picker, carries the colour picked, and choosing it opens the
  -- picker (MinimapButton.PickGlowColor, PickMarkerColor): each colour
  -- picked is worn at once, and Cancel puts back the choice before. `c`:
  -- title, text, ids (MinimapButton's list), names, get, set, pick, custom
  -- (the colour saved, or nil), rgb (a choice's colour); Get, Set, Pick,
  -- Custom and RGB name MinimapButton's functions, resolved at call time.
  local T = ns.Theme
  S.mmGlowCustom = T.CanPickColor and T.CanPickColor() and true or false
  local function ColorRow(c)
    local items = {}
    for _, id in ipairs(c.ids) do
      if id ~= "custom" or S.mmGlowCustom then items[#items + 1] = { id = id, name = c.names[id] } end
    end
    local row
    -- What the picker changed, in the list and the drawing.
    local function Picked()
      Rows.PaintDropdown(row)
      Ctx.Repaint()
    end
    row = Rows.Dropdown(block, {
      title = c.title, text = c.text, items = items,
      swatchFor = function(id)
        local I = ns.MinimapButton
        if not I then return nil end
        if id == "custom" then
          if I[c.custom] then return I[c.custom]() end
          return nil
        end
        if I[c.rgb] then return I[c.rgb](id) end
        return nil
      end,
      get = function() return ns.MinimapButton and ns.MinimapButton[c.get]() end,
      set = function(id)
        local I = ns.MinimapButton
        if not I then return end
        if id == "custom" then
          -- No picker: the list shows the choice that stands.
          if not (I[c.pick] and I[c.pick](Picked)) then Rows.PaintDropdown(row) end
        else
          I[c.set](id)
        end
        Ctx.Repaint()
      end,
    })
    return row
  end

  local colorNames = {
    red = L["OPT_MINIMAP_MARKERCOLOR_RED"], gold = L["OPT_MINIMAP_GLOWCOLOR_GOLD"],
    accent = L["OPT_MINIMAP_GLOWCOLOR_ACCENT"], class = L["OPT_COLOR_CLASS"], white = L["OPT_MINIMAP_GLOWCOLOR_WHITE"],
    custom = L["OPT_MINIMAP_GLOWCOLOR_CUSTOM"],
  }
  local glowRow = ColorRow({
    title = L["OPT_MINIMAP_GLOWCOLOR_TITLE"], text = L["OPT_MINIMAP_GLOWCOLOR_DESC"],
    ids = (Icon and Icon.GLOW_COLORS) or { "gold" }, names = colorNames,
    get = "GetGlowColor", set = "SetGlowColor", pick = "PickGlowColor", custom = "GetGlowCustom", rgb = "GlowRGB",
  })
  modes[glowRow.entry] = "glow"
  rows.glow = glowRow
  Rows.Why(glowRow, "OPT_MINIMAP_WHY_GLOWCOLOR")

  -- The flash is drawn on the icon, so with the icon off it has nothing to
  -- draw on: it greys with the rows around it. It wears Glow color, which
  -- stays live while it is on (State.MinimapRows).
  Rows.Check(block, {
    title = L["OPT_ALERT_FLASH_TITLE"], text = L["OPT_ALERT_FLASH_DESC"],
    get = function() return ns.MinimapButton and ns.MinimapButton.GetAlertFlash() end,
    set = function(on) if ns.MinimapButton then ns.MinimapButton.SetAlertFlash(on) end end,
    after = State.MinimapRows,
  })

  -- Expiring mail: the marker for mail close to being lost -- where it
  -- shows (nowhere, on the icon while When to show has it up, or also on
  -- its own where the icon sits; it never brings the icon up itself), its
  -- shape, its colour, the spot on the icon it is anchored to and how far
  -- it is moved from there, and whether, on its own, it grows into the
  -- icon's spot.
  Rows.Group(block, L["OPT_MINIMAP_GROUP_EXPIRY"])
  local expiryNames = {
    off = L["OPT_MINIMAP_EXPIRY_OFF"], icon = L["OPT_MINIMAP_EXPIRY_ICON"], always = L["OPT_MINIMAP_EXPIRY_ALWAYS"],
  }
  local expiryItems = {}
  for _, mode in ipairs((Icon and Icon.EXPIRY_MODES) or { "always" }) do
    expiryItems[#expiryItems + 1] = { id = mode, name = expiryNames[mode] }
  end
  local expiryRow = Rows.Dropdown(block, {
    title = L["OPT_MINIMAP_EXPIRY_TITLE"], text = L["OPT_MINIMAP_EXPIRY_DESC"], items = expiryItems,
    get = function() return ns.MinimapButton and ns.MinimapButton.GetExpiry() end,
    set = function(id)
      if ns.MinimapButton then ns.MinimapButton.SetExpiry(id) end
      State.MinimapRows()
      Ctx.Repaint()
    end,
  })
  modes[expiryRow.entry] = "expiry"

  -- Shape, Color, Anchor, Offset X and Offset Y grey while Show marker is
  -- Off; Larger when alone unless it is Always, the only choice that puts
  -- the marker on its own (State.MinimapRows).
  local markerNames = {
    dot = L["OPT_MINIMAP_MARKER_DOT"], ring = L["OPT_MINIMAP_MARKER_RING"], square = L["OPT_MINIMAP_MARKER_SQUARE"],
    bar = L["OPT_MINIMAP_MARKER_BAR"], exclamation = L["OPT_MINIMAP_MARKER_EXCLAMATION"],
    triangle = L["OPT_MINIMAP_MARKER_TRIANGLE"],
  }
  local markerItems = {}
  for _, id in ipairs((Icon and Icon.MARKER_SHAPES) or { "dot" }) do
    markerItems[#markerItems + 1] = { id = id, name = markerNames[id] }
  end
  local markerRow = Rows.Dropdown(block, {
    title = L["OPT_MINIMAP_MARKER_TITLE"], text = L["OPT_MINIMAP_MARKER_DESC"], items = markerItems,
    get = function() return ns.MinimapButton and ns.MinimapButton.GetMarker() end,
    set = function(id)
      if ns.MinimapButton then ns.MinimapButton.SetMarker(id) end
      Ctx.Repaint()
    end,
  })
  modes[markerRow.entry] = "marker"
  rows.marker = markerRow
  Rows.Why(markerRow, "OPT_MINIMAP_WHY_MARKER")
  local colorRow = ColorRow({
    title = L["OPT_MINIMAP_MARKERCOLOR_TITLE"], text = L["OPT_MINIMAP_MARKERCOLOR_DESC"],
    ids = (Icon and Icon.MARKER_COLORS) or { "red" }, names = colorNames,
    get = "GetMarkerColor", set = "SetMarkerColor", pick = "PickMarkerColor", custom = "GetMarkerCustom", rgb = "MarkerRGB",
  })
  modes[colorRow.entry] = "color"
  rows.color = colorRow
  Rows.Why(colorRow, "OPT_MINIMAP_WHY_MARKER")
  -- Anchor: the nine spots, in reading order; its drawing is the grid of
  -- them.
  local anchorNames = {
    TOPLEFT = L["OPT_MINIMAP_ANCHOR_TL"], TOP = L["OPT_MINIMAP_ANCHOR_T"], TOPRIGHT = L["OPT_MINIMAP_ANCHOR_TR"],
    LEFT = L["OPT_MINIMAP_ANCHOR_L"], CENTER = L["OPT_MINIMAP_ANCHOR_C"], RIGHT = L["OPT_MINIMAP_ANCHOR_R"],
    BOTTOMLEFT = L["OPT_MINIMAP_ANCHOR_BL"], BOTTOM = L["OPT_MINIMAP_ANCHOR_B"], BOTTOMRIGHT = L["OPT_MINIMAP_ANCHOR_BR"],
  }
  local cornerItems = {}
  for _, id in ipairs((Icon and Icon.MARKER_CORNERS) or { "TOPRIGHT" }) do
    cornerItems[#cornerItems + 1] = { id = id, name = anchorNames[id] }
  end
  local cornerRow = Rows.Dropdown(block, {
    title = L["OPT_MINIMAP_ANCHOR_TITLE"], text = L["OPT_MINIMAP_ANCHOR_DESC"], items = cornerItems,
    get = function() return ns.MinimapButton and ns.MinimapButton.GetMarkerCorner() end,
    set = function(id)
      if ns.MinimapButton then ns.MinimapButton.SetMarkerCorner(id) end
      Ctx.Repaint()
    end,
  })
  modes[cornerRow.entry] = "corner"
  rows.corner = cornerRow
  Rows.Why(cornerRow, "OPT_MINIMAP_WHY_MARKER")
  -- Offset X and Offset Y: whole screen pixels from the anchor. No answers
  -- of their own: the drawing shows the icon as set, the marker moving with
  -- the slider, and their text stands under it.
  local lo = (Icon and Icon.MARKER_OFFSET_MIN) or -20
  local hi = (Icon and Icon.MARKER_OFFSET_MAX) or 20
  rows.offx = Rows.Slider(block, {
    title = L["OPT_MINIMAP_OFFSETX_TITLE"], text = L["OPT_MINIMAP_OFFSETX_DESC"], min = lo, max = hi,
    get = function() return ns.MinimapButton and ns.MinimapButton.GetMarkerX() end,
    set = function(v) if ns.MinimapButton then ns.MinimapButton.SetMarkerX(v) end end,
    after = Ctx.Repaint,
  })
  Rows.Why(rows.offx, "OPT_MINIMAP_WHY_MARKER")
  rows.offy = Rows.Slider(block, {
    title = L["OPT_MINIMAP_OFFSETY_TITLE"], text = L["OPT_MINIMAP_OFFSETY_DESC"], min = lo, max = hi,
    get = function() return ns.MinimapButton and ns.MinimapButton.GetMarkerY() end,
    set = function(v) if ns.MinimapButton then ns.MinimapButton.SetMarkerY(v) end end,
    after = Ctx.Repaint,
  })
  Rows.Why(rows.offy, "OPT_MINIMAP_WHY_MARKER")
  local largeRow = Rows.Check(block, {
    title = L["OPT_MINIMAP_LARGE_TITLE"], text = L["OPT_MINIMAP_LARGE_DESC"],
    get = function() return ns.MinimapButton and ns.MinimapButton.GetMarkerLarge() end,
    set = function(on) if ns.MinimapButton then ns.MinimapButton.SetMarkerLarge(on) end end,
    after = Ctx.Repaint,
  })
  modes[largeRow.entry] = "large"
  rows.large = largeRow
  Rows.Why(largeRow, "OPT_MINIMAP_WHY_ALONE")
  for entry in pairs(modes) do entry.stage = "minimap" end
  rows.offx.entry.stage, rows.offy.entry.stage = "minimap", "minimap"

  -- Place: where it sits on the map, and the lock on moving it. Under
  -- EllesmereUI's minimap that, and the size, are EllesmereUI's, and one
  -- quiet line says so in their place.
  Rows.Group(block, L["OPT_MINIMAP_GROUP_PLACE"])
  if hostStyled then
    -- One quiet line, not a paragraph: the whole of it is in the inspector.
    Rows.Note(block, L["OPT_MINIMAP_EUI_SHORT"], L["OPT_MINIMAP_EUI_SHORT"], L["OPT_MINIMAP_EUI_STYLED"])
  else
    -- Every placement in ONE list -- a mode checkbox beside a position list
    -- gave two controls authority over one fact, and they contradicted
    -- each other the moment shift-drag moved the icon. Blizzard default
    -- leads: it is where the stock indicator lives. A fresh install starts
    -- in the top-right corner (MinimapButton's DEFAULTS.position), and
    -- picking that corner again is the way back to it after a shift-drag.
    Rows.Dropdown(block, {
      title = L["OPT_MINIMAP_POS_TITLE"], text = L["OPT_MINIMAP_POS_DESC"],
      items = {
        { id = "BLIZZARD",    name = L["OPT_MINIMAP_POS_BLIZZARD"] },
        { id = "TOPRIGHT",    name = L["OPT_MINIMAP_POS_TR"] },
        { id = "TOPLEFT",     name = L["OPT_MINIMAP_POS_TL"] },
        { id = "BOTTOMRIGHT", name = L["OPT_MINIMAP_POS_BR"] },
        { id = "BOTTOMLEFT",  name = L["OPT_MINIMAP_POS_BL"] },
        { id = "CUSTOM",      name = L["OPT_MINIMAP_POS_CUSTOM"] },
        { id = "FREE",        name = L["OPT_MINIMAP_POS_FREE"] },
      },
      get = function() return ns.MinimapButton and ns.MinimapButton.GetPosition() end,
      set = function(id) if ns.MinimapButton then ns.MinimapButton.SetPosition(id) end end,
    })
    Rows.Check(block, {
      title = L["OPT_MINIMAP_LOCK_TITLE"], text = L["OPT_MINIMAP_LOCK_DESC"],
      get = function() return ns.MinimapButton and ns.MinimapButton.GetLocked() end,
      set = function(on) if ns.MinimapButton then ns.MinimapButton.SetLocked(on) end end,
    })
  end
  Rows.EndBlock(block)
end

-- Mail Memory: every character's last-seen mailbox -- a window of its own
-- away from the mailbox, and the other characters in the Mail tab at one.
function Pages.memory(col)
  local T = ns.Theme
  Rows.Check(col, {
    master = true, title = L["OPT_MEMORY_SWITCH"], entryTitle = L["OPT_MEMORY_TITLE"],
    text = L["OPT_MEMORY_DESC"],
    get = function() return ns.MailboxUI.GetOption("mailMemory") end,
    set = function(on)
      ns.MailboxUI.SetOption("mailMemory", on)
      if ns.MailboxUI.RefreshMemoryState then ns.MailboxUI.RefreshMemoryState() end
    end,
    after = State.Memory,
  })

  local block = Rows.Block(col)
  S.memoryBlock = block
  Rows.Check(block, {
    title = L["OPT_ALERT_OTHERS_TITLE"], text = L["OPT_ALERT_OTHERS_DESC"],
    get = function() return ns.MailboxUI.GetOption("mailWarnings") end,
    set = function(on) ns.MailboxUI.SetOption("mailWarnings", on) end,
  })

  -- Hidden characters: the caption, the names, and Show all.
  local row = Rows.New(block, ROW_H)
  Rows.Cell(block, row, ROW_W, L["HIDDEN_TITLE"], L["HIDDEN_DESC"])
  row.kind = "hidden"
  local showAll = T.CreateButton(nil, row)
  showAll:SetHeight(CHECK_H)
  showAll:SetPoint("RIGHT", row, "RIGHT", -CONTROL_R, 0)
  showAll:SetText(L["OPT_HIDDEN_SHOW_ALL"])
  showAll:SetScript("OnClick", function()
    local Memory = ns.MailMemory
    if Memory and type(Memory.ShowAllHidden) == "function" then Memory.ShowAllHidden() end
  end)
  showAll.__pbCell = row
  showAll.__pbEntry = Entry(L["OPT_HIDDEN_SHOW_ALL"], L["OPT_HIDDEN_SHOW_ALL_DESC"])
  if showAll.SetMotionScriptsWhileDisabled then showAll:SetMotionScriptsWhileDisabled(true) end
  showAll:HookScript("OnEnter", Rows.ControlEnter)
  showAll:HookScript("OnLeave", Rows.ControlLeave)
  showAll:Hide()
  local names = T.CreateText(row, "secondary")
  names:SetJustifyH("RIGHT")
  names:SetWordWrap(false)
  row.more, row.Names, row.lines = showAll, names, {}
  -- Its tooltip also lists every name the row may have cut.
  local function HiddenEnter(self)
    if Rows.Held(self, HiddenEnter) then return end
    Rows.Hover(self)
    local tip = Tip.Begin(self, self.entry.title, ns.Summary(self.entry.text))
    -- The names are its facts, under what it does; the rest counted, muted.
    -- No blank line: the house keeps that for the hints.
    local lines = self.lines
    for i = 1, #lines do tip:AddLine(lines[i], 1, 1, 1) end
    if self.moreLine then
      local muted = ns.Theme.TIP_MUTED
      tip:AddLine(self.moreLine, muted, muted, muted)
    end
    Tip.Show(self)
  end
  row:SetScript("OnEnter", HiddenEnter)
  row:SetScript("OnLeave", Rows.LeaveRow)
  S.hiddenRow = row
  Rows.EndBlock(block)
end

-------------------------------------------------------------
-- Reset this tab: which settings are the tab's
--
-- The footer's narrowest reset puts back the settings on the tab the player
-- is looking at. Which saved values those are is written down nowhere: it
-- is read off the tab's own rows when the reset is answered, so a row added
-- next month is in it without anyone having to remember. A value is the
-- tab's when it moves what one of the tab's rows shows, found by asking the
-- rows with the profile set two ways for every value: everything at its
-- default but that one value, and everything as it is but that one value.
-- Either moving a row claims it -- the first finds an old key a getter
-- still carries over when the new one is unset, the second a value that
-- counts only beside another (a custom colour's hex beside its choice). A
-- table's entries are judged one by one: the minimap icon's settings share
-- one table, and its alert sound is a Mail tab row.
--
-- A look's own values are named for it: pb (the Postbox style, and the
-- creative styles drawn on it), eui (the EllesmereUI skin), modern (the
-- retired Postbox Modern), style (which look). Only the look being worn has
-- rows, so the tab the Style row stands on takes all of them: a look reset
-- there is not found wearing its old settings when it is next chosen.
--
-- The asking writes the profile directly, and it is put back exactly as it
-- was before anything is cleared: the clearing is MailboxUI's
-- (UI.ResetSettingKeys), with what the other resets keep kept. One run, on
-- the answer; a few hundred reads, and nothing on screen moves meanwhile.
-------------------------------------------------------------
local TabReset = {}
do
  local LOOK_FAMILIES = { "pb", "eui", "modern", "style" }
  -- What a row answered when it answered nothing, or failed to answer.
  local NONE, FAILED = {}, {}

  local function Copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = Copy(x) end
    return out
  end

  -- A look's own value: a family's name, then nothing or a capital.
  local function LookKey(key)
    if type(key) ~= "string" then return false end
    for i = 1, #LOOK_FAMILIES do
      local f = LOOK_FAMILIES[i]
      if key:sub(1, #f) == f then
        local after = key:sub(#f + 1, #f + 1)
        if after == "" or after:match("^%u$") then return true end
      end
    end
    return false
  end

  -- Every value the profile holds that a reset may clear, as { key } or
  -- { key, sub }: a table's entries one by one.
  local function UnitsOf(snap, keeps)
    local units = {}
    for key, value in pairs(snap) do
      if type(value) == "table" then
        for sub in pairs(value) do
          if not keeps(key, sub) then units[#units + 1] = { key, sub } end
        end
      elseif not keeps(key) then
        units[#units + 1] = { key }
      end
    end
    return units
  end

  -- The profile as `snap` has it, but with every unit cleared that `on`
  -- leaves out: `alone`, all but `only`; otherwise all but everything except
  -- `only`. What a row's getter wrote while it was asked (a default seeded,
  -- an old key carried over) goes first, so every reading starts on the
  -- same ground. A table is never taken away, only emptied: the store and
  -- the modules hold theirs.
  local function Put(profile, snap, units, keeps, alone, only)
    for key, value in pairs(profile) do
      local was = snap[key]
      if was == nil then
        if not keeps(key) then
          if type(value) == "table" then
            for inner in pairs(value) do value[inner] = nil end
          else
            profile[key] = nil
          end
        end
      elseif type(value) == "table" and type(was) == "table" then
        for inner in pairs(value) do
          if was[inner] == nil then value[inner] = nil end
        end
      end
    end
    for i = 1, #units do
      local unit = units[i]
      local on
      if alone then on = (unit == only) else on = (unit ~= only) end
      local key, sub = unit[1], unit[2]
      if sub == nil then
        if on then profile[key] = Copy(snap[key]) else profile[key] = nil end
      else
        local t = profile[key]
        if type(t) ~= "table" then
          t = {}
          profile[key] = t
        end
        if on then t[sub] = Copy(snap[key][sub]) else t[sub] = nil end
      end
    end
  end

  -- What each row shows now, into `out`.
  local function Read(gets, out)
    local UI = ns.MailboxUI
    if UI and type(UI.ForgetSettings) == "function" then UI.ForgetSettings() end
    for i = 1, #gets do
      local ok, v = pcall(gets[i])
      if not ok then v = FAILED elseif v == nil then v = NONE end
      out[i] = v
    end
  end

  local function Differs(a, b, n)
    for i = 1, n do
      if a[i] ~= b[i] then return true end
    end
    return false
  end

  local function Probe(profile, snap, units, keeps, gets, looks, owned)
    local n = #gets
    local base, full, now = {}, {}, {}
    Put(profile, snap, units, keeps, true, nil)
    Read(gets, base)
    Put(profile, snap, units, keeps, false, nil)
    Read(gets, full)
    for i = 1, #units do
      local unit = units[i]
      local mine = looks and LookKey(unit[1])
      if not mine and n > 0 then
        Put(profile, snap, units, keeps, true, unit)
        Read(gets, now)
        mine = Differs(now, base, n)
        if not mine then
          Put(profile, snap, units, keeps, false, unit)
          Read(gets, now)
          mine = Differs(now, full, n)
        end
      end
      if mine then owned[#owned + 1] = unit end
    end
  end

  -- The settings on tab `key`, as UI.ResetSettingKeys takes them, or nil
  -- where they cannot be worked out (nothing is then reset).
  function TabReset.Units(key)
    local UI, store = ns.MailboxUI, ns.Store
    local profile = store and store.Get and store.Get("profile")
    local range = S.tabCells[key]
    if type(profile) ~= "table" or not range or not (UI and type(UI.ResetKeeps) == "function") then
      return nil
    end
    local keeps = UI.ResetKeeps
    local gets, looks = {}, false
    for i = range[1], range[2] do
      local cell = S.cells[i]
      if (cell.kind == "check" or cell.kind == "dropdown" or cell.kind == "slider") and type(cell.get) == "function" then
        gets[#gets + 1] = cell.get
      end
      if cell == S.styleCell then looks = true end
    end
    local snap = Copy(profile)
    local units = UnitsOf(snap, keeps)
    local owned = {}
    local ok, err = pcall(Probe, profile, snap, units, keeps, gets, looks, owned)
    -- Back as it was, whatever happened above.
    Put(profile, snap, units, keeps, false, nil)
    if type(UI.ForgetSettings) == "function" then UI.ForgetSettings() end
    if not ok then
      if type(geterrorhandler) == "function" then geterrorhandler()(err) end
      return nil
    end
    return owned
  end

  -- The tab's name, as its tab says it.
  function TabReset.Name(key)
    for i = 1, #TABS do
      if TABS[i].key == key then return L[TABS[i].caption] end
    end
    return key
  end
end

-------------------------------------------------------------
-- The footer
--
-- A band under the list and the inspector with three things on it, each
-- where it reads evenly: Reset to defaults at its left end, the one door
-- out to a bug report in its middle, What's new? at its right end. What
-- this build is stands under the band's right end, small and dim, outside
-- it: a fact about the build, not a control.
-------------------------------------------------------------
-- The band's width; Report a bug never nearer the item at either end than
-- MID_GAP; the band to the version, and the version to the panel's foot.
Footer.BAND_W = PANEL_W - 2 * EDGE
Footer.MID_GAP, Footer.VERSION_GAP, Footer.VERSION_FOOT = 16, 3, 7

-- One of the theme's glyphs, white like the band's text beside it, or nil
-- where the theme has none: the band then reads as words alone.
function Footer.Glyph(parent, name, size)
  local T = ns.Theme
  local glyph = T and type(T.Glyph) == "function" and T.Glyph(parent, name, size, "ARTWORK") or nil
  if glyph then T.SetColor(glyph, "textPrimary") end
  return glyph
end

function Footer.Build(frame, above)
  local T = ns.Theme
  local statusBand = CreateFrame("Button", nil, frame, "BackdropTemplate")
  statusBand:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -BODY_GAP)
  statusBand:SetPoint("RIGHT", frame, "RIGHT", -EDGE, 0)
  statusBand:SetHeight(BAND_H)
  T.ApplyBand(statusBand)

  -- Quiet until pointed at, in the quiet text colour and its mark with it,
  -- at full strength: a colour of the band's own, never a dimmed one.
  local statusText = T.CreateText(statusBand, "secondary")
  statusText:SetJustifyH("LEFT")
  statusText:SetWordWrap(false)
  -- Says what the click does. The band has always opened the bug report;
  -- nothing on it ever said so.
  statusText:SetText(L["OPT_REPORT_BUG"])
  -- Its mark before it.
  local bugArt = ArtHolder(statusBand)
  local bug = Footer.Glyph(bugArt, "bug", 12)
  if bug then
    bug:SetPoint("CENTER", statusText, "LEFT", -11, 0)
    T.SetColor(bug, "textSecondary")
  end

  -- What's new? (Core/WhatsNew.lua), at the band's right end, as quiet as
  -- Report a bug: a button of its own laid over the band, as Reset to
  -- defaults is, so a click on it is never also the bug report's.
  local news = CreateFrame("Button", nil, statusBand)
  news:SetFrameLevel(statusBand:GetFrameLevel() + 2)
  news:SetPoint("TOPRIGHT", statusBand, "TOPRIGHT", -8, 0)
  news:SetPoint("BOTTOMRIGHT", statusBand, "BOTTOMRIGHT", -8, 0)
  local newsText = T.CreateText(news, "secondary")
  newsText:SetPoint("RIGHT", news, "RIGHT", 0, 0)
  newsText:SetJustifyH("RIGHT")
  newsText:SetWordWrap(false)
  newsText:SetText(L["WHATSNEW_TITLE"])
  news:SetScript("OnClick", function()
    local News = ns.WhatsNew
    if News and type(News.Toggle) == "function" then News.Toggle(frame, true) end
  end)
  news:SetScript("OnEnter", function() T.SetColor(newsText, "textPrimary") end)
  news:SetScript("OnLeave", function() T.SetColor(newsText, "textSecondary") end)

  -- The version, under the band's right end in the game's smallest face (in
  -- the host's where it has one), quiet: the disabled grey, at full
  -- strength. Only words: What's new? above it is the door. It stands on
  -- the window itself, so it has a plate of its own where the window cannot
  -- carry it (Theme.OnWindow). The packager stamps the release TAG into the
  -- TOC, which already carries its own "v" -- do not add another.
  local versionText = T.CreateText(frame, "secondary")
  local tiny = _G.GameFontWhiteTiny
  if tiny then versionText:SetFontObject(T.HostFont(tiny)) end
  T.SetColor(versionText, "textDisabled")
  versionText:SetPoint("TOPRIGHT", statusBand, "BOTTOMRIGHT", -8, -Footer.VERSION_GAP)
  versionText:SetJustifyH("RIGHT")
  versionText:SetWordWrap(false)
  versionText:SetText(tostring(ns.VERSION or ""))
  if T.OnWindow then T.OnWindow(versionText, "solid") end

  S.footer = {
    band = statusBand, bugText = statusText, bugMark = bug and 17 or 0,
    news = news, newsText = newsText, version = versionText,
  }

  -- Reset to defaults, at the band's left end across from What's new?: the
  -- one control here that undoes the player's own choices, so it is quiet
  -- until pointed at. A button of its own laid over the band, so a click on
  -- it is never also a click on the bug report.
  --
  -- A click opens a small menu of the three resets, narrowest first: the
  -- settings on the tab the panel is showing (TabReset), every setting, or
  -- everything Postbox keeps but the list of the player's characters. Each
  -- says in its tooltip what it clears and what it keeps, and choosing one
  -- asks that reset's own question, which says it in full; nothing changes
  -- until it is answered. Cancel and Escape change nothing, and Enter answers
  -- no question (no enterClicksFirstButton). The tab is the one the menu was
  -- opened on and names, whichever tab the panel has moved to by the answer.
  do
    local POPUP_RESET_TAB = "POSTBOX_RESET_TAB"
    local POPUP_RESET = "POSTBOX_RESET_SETTINGS"
    local POPUP_RESET_ALL = "POSTBOX_RESET_EVERYTHING"

    -- Either reset ends here: the panel re-reads its controls, and the
    -- style -- the one setting that waits for a reload -- makes the offer a
    -- style change makes. Nothing else needs one: everything a reset
    -- touches is put back on screen as it happens (MailboxUI, the resets).
    local function AfterReset(styleChanged)
      -- Everything can clear the recipients: the Send tab's tile counts
      -- them again.
      S.sendText = nil
      Panel.RefreshControls()
      if styleChanged then OfferStyleReload() end
    end

    -- No reset runs while Postbox is collecting or sending (MailboxUI,
    -- UI.ResetBlockedBy): true, and a line in chat saying what to wait for.
    -- Asked at the footer's click, at the menu's pick and again at every
    -- answer, since a run can start while a question stands.
    local function Busy()
      local UI = ns.MailboxUI
      local by = UI and type(UI.ResetBlockedBy) == "function" and UI.ResetBlockedBy() or nil
      if not by then return false end
      ns.Print(L[by == "send" and "MSG_RESET_WAIT_SEND" or "MSG_RESET_WAIT_COLLECT"])
      return true
    end

    local function ResetSettingsNow()
      local UI = ns.MailboxUI
      if Busy() or not (UI and type(UI.ResetSettings) == "function") then return end
      local styleChanged, refused = UI.ResetSettings()
      if not refused then AfterReset(styleChanged) end
    end

    local function ResetTabNow()
      local UI = ns.MailboxUI
      if Busy() or not (UI and type(UI.ResetSettingKeys) == "function") then return end
      local units = TabReset.Units(S.resetTab)
      if not units then return end
      local styleChanged, refused = UI.ResetSettingKeys(units)
      if not refused then AfterReset(styleChanged) end
    end

    local function ResetEverythingNow()
      local UI = ns.MailboxUI
      if Busy() or not (UI and type(UI.ResetEverything) == "function") then return end
      local styleChanged, refused = UI.ResetEverything()
      if refused then return end
      AfterReset(styleChanged)
      ns.Print(L["MSG_RESET_ALL_DONE"])
    end

    -- One question per reset, its answer the reset or nothing.
    local function Question(onAccept)
      return {
        text = "%s",
        button1 = L["BTN_RESET"],
        button2 = L["COD_CONFIRM_CANCEL"],
        OnAccept = onAccept,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        showAlert = true,
        -- Its text says what goes and what stays: the popup's wider width.
        wideText = true,
      }
    end

    -- Registered on first use, like the reload offer. No popup, no reset:
    -- this never happens without the question being asked.
    local function EnsureResetDialogs()
      if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then
        return false
      end
      if not StaticPopupDialogs[POPUP_RESET_TAB] then StaticPopupDialogs[POPUP_RESET_TAB] = Question(ResetTabNow) end
      if not StaticPopupDialogs[POPUP_RESET] then StaticPopupDialogs[POPUP_RESET] = Question(ResetSettingsNow) end
      if not StaticPopupDialogs[POPUP_RESET_ALL] then StaticPopupDialogs[POPUP_RESET_ALL] = Question(ResetEverythingNow) end
      return true
    end

    -- A pick from the menu: its own question, with what it says filled in.
    local function Ask(id)
      if Busy() or not EnsureResetDialogs() then return end
      if id == "tab" then
        S.resetTab = S.tab
        ns.Theme.LiftPopup(StaticPopup_Show(POPUP_RESET_TAB, L("OPTX_RESET_TAB_CONFIRM", TabReset.Name(S.tab))))
      elseif id == "settings" then
        ns.Theme.LiftPopup(StaticPopup_Show(POPUP_RESET, L["MSG_RESET_SETTINGS_CONFIRM"]))
      elseif id == "everything" then
        ns.Theme.LiftPopup(StaticPopup_Show(POPUP_RESET_ALL, L["MSG_RESET_ALL_CONFIRM"]))
      end
    end

    local reset = CreateFrame("Button", nil, statusBand)
    reset:SetPoint("TOPLEFT", statusBand, "TOPLEFT", 4, 0)
    reset:SetPoint("BOTTOMLEFT", statusBand, "BOTTOMLEFT", 4, 0)
    reset:SetFrameLevel(statusBand:GetFrameLevel() + 2)
    -- Its arrow before it and a caret after: a choice opens from here.
    local arrow = Footer.Glyph(reset, "reset", 12)
    local caret = Footer.Glyph(reset, "caret", 6)
    local resetText = ns.Theme.CreateText(reset, "bodySmall")
    resetText:SetPoint("LEFT", reset, "LEFT", arrow and 21 or 4, 0)
    resetText:SetWordWrap(false)
    resetText:SetText(L["OPT_RESET_DEFAULTS"])
    S.footer.resetText = resetText
    if arrow then arrow:SetPoint("CENTER", reset, "LEFT", 10, 0) end
    if caret then caret:SetPoint("CENTER", resetText, "RIGHT", 9, 0) end
    -- At rest the band's quiet text colour, as Report a bug and What's new?
    -- are, at full strength; the text colour when pointed at, and while its
    -- menu is open.
    local menu
    local function Quiet(on)
      if on and menu and menu:IsShown() then on = false end
      local token = on and "textSecondary" or "textPrimary"
      ns.Theme.SetColor(resetText, token)
      if arrow then ns.Theme.SetColor(arrow, token) end
      if caret then ns.Theme.SetColor(caret, token) end
    end
    Quiet(true)
    -- As wide as what it says, re-measured on every open (Footer.Fit): a
    -- host skin can re-font it after the panel is built.
    S.footer.FitReset = function()
      local width = math.ceil(resetText:GetStringWidth() or 0) + (arrow and 21 or 4) + (caret and 18 or 4)
      reset:SetWidth(width)
      return width
    end

    -- The menu's three, each with a tooltip of what it clears and keeps:
    -- the tab's names the tab the panel shows.
    local RESETS = {
      { id = "tab", name = L["OPTX_RESET_TAB"] },
      { id = "settings", name = L["BTN_RESET_SETTINGS"] },
      { id = "everything", name = L["BTN_RESET_EVERYTHING"] },
    }
    local function ResetTip(row, item)
      local text
      if item.id == "tab" then
        text = L("OPT_RESET_TAB_TIP", TabReset.Name(S.tab))
      elseif item.id == "settings" then
        text = L["OPT_RESET_SETTINGS_TIP"]
      else
        text = L["OPT_RESET_EVERYTHING_TIP"]
      end
      Tip.Begin(row, item.name, text)
      Tip.Show(row)
    end
    local function ResetUntip() GameTooltip:Hide() end

    reset:SetScript("OnClick", function(self)
      GameTooltip:Hide()
      if not menu then
        local Drop = ns.Core.UI.Dropdown
        if not (Drop and type(Drop.Menu) == "function") then return end
        menu = Drop.Menu(self, RESETS, {
          onPick = Ask,
          onEnter = ResetTip,
          onLeave = ResetUntip,
          -- However it closed: quiet again unless the pointer is on it.
          onClose = function() Quiet(not reset:IsMouseOver()) end,
          minWidth = math.max(120, self:GetWidth() or 0),
        })
      end
      if not menu:IsShown() and Busy() then return end
      menu:Toggle()
      Quiet(false)
    end)
    reset:SetScript("OnEnter", function(self)
      Quiet(false)
      if menu and menu:IsShown() then return end
      Tip.Begin(self, L["OPT_RESET_DEFAULTS"], L["OPT_RESET_DEFAULTS_DESC"])
      Tip.Show(self)
    end)
    reset:SetScript("OnLeave", function()
      Quiet(true)
      GameTooltip:Hide()
    end)
  end

  -- The bug-report window (BugReport, above), built on first use. The
  -- panel's refresh repaints its recording switch, and after a reset takes
  -- the record down with the cleared choice.
  local function ToggleBugReport() BugReport.Toggle(frame) end
  S.refresh[#S.refresh + 1] = BugReport.Sync
  -- /postbox debug reaches this without the panel being open.
  Panel._toggleBugReport = ToggleBugReport

  statusBand:SetScript("OnClick", ToggleBugReport)
  statusBand:SetScript("OnEnter", function(self)
    T.SetColor(statusText, "textPrimary")
    if bug then T.SetColor(bug, "textPrimary") end
    Tip.Begin(self, L["OPT_BUG_TIP_TITLE"], L["OPT_BUG_TIP_DESC"])
    Tip.Show(self)
  end)
  statusBand:SetScript("OnLeave", function()
    T.SetColor(statusText, "textSecondary")
    if bug then T.SetColor(bug, "textSecondary") end
    GameTooltip:Hide()
  end)
end

-- Measured on every open, after the skins have had their say about fonts,
-- and in whatever language the client speaks. The ends are held: Reset to
-- defaults 4 in from the band's left, What's new? 8 in from its right.
-- Report a bug, its mark and its words as one, stands in the band's middle;
-- only where that would bring it nearer either end's item than MID_GAP (a
-- long translation) does it move, to the middle of the room between them.
-- The panel's foot is as tall as the version under the band needs.
function Footer.Fit()
  local f = S.footer
  if not f then return end
  local resetR = 4 + f.FitReset()
  local newsW = math.max(1, math.ceil(TextW(f.newsText)))
  f.news:SetWidth(newsW)
  local newsL = Footer.BAND_W - 8 - newsW
  local mark = f.bugMark
  local unit = mark + math.ceil(TextW(f.bugText))
  local x = (Footer.BAND_W - unit) / 2
  if x < resetR + Footer.MID_GAP or x + unit > newsL - Footer.MID_GAP then
    x = resetR + (newsL - resetR - unit) / 2
  end
  x = math.floor(x + 0.5)
  f.bugText:ClearAllPoints()
  f.bugText:SetPoint("LEFT", f.band, "LEFT", x + mark, 0)
  S.footH = math.max(FOOT_BOTTOM,
    Footer.VERSION_GAP + math.ceil(f.version:GetStringHeight() or 0) + Footer.VERSION_FOOT)
end

-------------------------------------------------------------
-- Build, refresh, layout
-------------------------------------------------------------

-- Every control from its source of truth, and every state that follows.
local function Refresh()
  local cells = S.cells
  for i = 1, #cells do
    local cell = cells[i]
    if cell.kind == "check" then
      local ok, on = pcall(cell.get)
      cell.control:SetChecked(ok and on and true or false)
    elseif cell.kind == "dropdown" then
      Rows.PaintDropdown(cell)
    elseif cell.kind == "slider" then
      Rows.PaintSlider(cell)
    end
  end
  for i = 1, #S.refresh do pcall(S.refresh[i]) end
end

-- What the texts' heights depend on, as they were last measured: the
-- measuring strings' fonts (a host skin's re-font moves them), their scale,
-- and the texts themselves (textGen). The same on an open means the same
-- heights, and nothing is laid out again.
local measuredWith = { false, false, false, false, false, false, false, false }

local function MeasuredAlready()
  local m = S.measure
  local p1, s1, f1 = m.Title:GetFont()
  local p2, s2, f2 = m.Text:GetFont()
  local scale, gen = m:GetEffectiveScale(), S.textGen
  local k = measuredWith
  if k[1] == p1 and k[2] == s1 and k[3] == f1 and k[4] == p2 and k[5] == s2 and k[6] == f2
      and k[7] == scale and k[8] == gen then
    return true
  end
  k[1], k[2], k[3], k[4], k[5], k[6], k[7], k[8] = p1, s1, f1, p2, s2, f2, scale, gen
  return false
end

-- The list and the inspector are one height, the tallest either needs, so
-- the panel never jumps as the tabs change: the tallest page of rows, or
-- the tallest description the inspector can be asked for -- measured in
-- the client's language and the host's font, with the drawing it must
-- leave room for where it sits under one. In English the pages set it;
-- only a language whose descriptions run longer makes the panel taller.
local function Layout()
  local text = S.textNeed
  if not (MeasuredAlready() and text) then
    text = 0
    -- The Minimap drawing's captions first: its height counts them.
    Ctx.MeasureCaptions()
    -- The Mail tab's text zone, under its window: the tab's own text and
    -- every setting's the window shows, the tallest of them.
    local mailText = SAY_MIN
    local entries = S.entries
    for i = 1, #entries do
      local entry = entries[i]
      local h = Insp.Need(entry, entry.extra and Ctx.ExtraHeight(entry.extra) or 0)
      -- A setting its tab's drawing answers (`stage`: that tab) has its text
      -- under the drawing, never over it.
      if entry.stage == "mail" then
        if h > mailText then mailText = h end
      else
        if entry.stage then h = Ctx.Height(entry.stage) + math.max(h, SAY_MIN) end
        if h > text then text = h end
      end
    end
    for i = 1, #TABS do
      local key = TABS[i].key
      local entry = S.idle[key]
      if key == "mail" then
        if entry then mailText = math.max(mailText, Insp.Need(entry, 0)) end
      else
        local ctxH = Ctx.Height(key)
        if entry and ctxH > 0 then
          local h = Insp.Need(entry, 0)
          if h < SAY_MIN then h = SAY_MIN end
          if ctxH + h > text then text = ctxH + h end
        end
      end
    end
    S.mailText = math.ceil(mailText)
    S.textNeed = text
  end
  -- The Mail tab: its window at its least over its text zone. The window
  -- then takes whatever room the panel has between the two (Ctx.MailFill),
  -- so it never makes the panel taller unless even its least needs it.
  text = math.max(text, Ctx.MailNeed(S.mailText))
  local need = math.ceil(math.max(S.listNeed or 0, text))
  local height = TOP + TAB_H + BODY_GAP + need + BODY_GAP + BAND_H + (S.footH or FOOT_BOTTOM)
  if need ~= S.bodyH or height ~= S.frameH then
    S.bodyH, S.frameH = need, height
    S.body:SetHeight(need)
    S.list:SetHeight(need)
    S.insp:SetHeight(need)
    S.frame:SetHeight(height)
    -- Never taller than the screen, whatever the window scale.
    local T = ns.Theme
    if T and type(T.FitToScreen) == "function" then T.FitToScreen(S.frame) end
  end
  Ctx.MailFill(need, S.mailText)
end

-- The pointer left the list and the inspector from somewhere no row is --
-- held, like any leave, while a dropdown's list is open (Rows.Hold).
local function BodyLeave(self)
  if self:IsMouseOver() or S.held then return end
  local washed = S.washed
  if washed and washed.Wash then washed.Wash:Hide() end
  S.washed = nil
  Insp.Show(nil)
end

-- Closing stops everything the panel set moving.
local function PanelHide()
  local washed = S.washed
  if washed and washed.Wash then washed.Wash:Hide() end
  S.washed, S.held, S.heldAt, S.heldEnter = nil, nil, nil, nil
  Insp.Show(nil)
  for _, f in pairs(S.ctx) do
    if f.Stop then f.Stop() end
  end
  -- Forever's reload offer goes with the panel that asked it.
  ReloadAsk.Hide()
end

local function Build()
  if S.frame then return S.frame end
  local T = ns.Theme

  local frame = CreateFrame("Frame", "PostboxOptionsFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:Hide()
  frame:SetSize(PANEL_W, 480)

  -- Never transparent: you need to read it while adjusting the transparency
  -- of the window behind it. Skin.ApplyBgOpacity honours this flag.
  frame.__pbEuiAlwaysOpaque = true

  -- TitleText is not guaranteed: Blizzard has been moving it behind
  -- TitleContainer, and the TOC declares two interface versions. The main
  -- window and the recipient manager already guard the identical access on
  -- the identical template; an unguarded index here would make the options
  -- panel permanently unreachable rather than merely untitled.
  if frame.SetTitle then
    frame:SetTitle(L["OPTIONS_TITLE"])
  elseif frame.TitleText then
    frame.TitleText:SetText(L["OPTIONS_TITLE"])
  end
  T.ApplyFrameTheme(frame)
  ns.Core.UI.Helpers.RegisterEscClose(frame)
  S.frame = frame
  S.installedHost = InstalledHostName()

  -- What the inspector says at rest on each tab: the tile's own words on
  -- the two tabs with one, the look's source on Window, the switch's own
  -- on the two tabs a switch leads. The Window and Minimap texts are
  -- settled below, once it is known what is painting.
  S.idle.mail = Entry(L["GROUPS_TITLE"], L["GROUPS_OPT_DESC"])
  S.idle.send = Entry(L["RM_OPT_BUTTON"], L["RM_OPT_BUTTON_DESC"])
  S.idle.window = Entry(L["OPT_STYLE_TITLE"], L["OPT_STYLE_DESC"])
  S.idle.minimap = Entry(L["OPT_MINIMAP_TITLE"], L["OPT_MINIMAP_DESC"])
  S.idle.memory = Entry(L["OPT_MEMORY_TITLE"], L["OPT_MEMORY_DESC"])

  Tabs.Build(frame)

  -- The body: the list and the inspector, and the gap between them, as one
  -- place the pointer can be (see the inspector's rule). Motion only.
  local top = TOP + TAB_H + BODY_GAP
  local body = CreateFrame("Frame", nil, frame)
  body:SetPoint("TOPLEFT", frame, "TOPLEFT", EDGE, -top)
  body:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -EDGE, -top)
  body:SetHeight(300)
  body:EnableMouse(true)
  if body.SetPropagateMouseClicks then body:SetPropagateMouseClicks(true) end
  body:SetScript("OnLeave", BodyLeave)
  S.body = body

  -- Both on the list surface the main window's panels use, so every skin
  -- already knows how to paint them.
  local list = CreateFrame("Frame", nil, body, "BackdropTemplate")
  list:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  list:SetSize(LIST_W, 300)
  T.ApplyList(list)
  local insp = CreateFrame("Frame", nil, body, "BackdropTemplate")
  insp:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
  insp:SetSize(INSP_W, 300)
  T.ApplyList(insp)
  S.list, S.insp = list, insp
  Insp.Build(insp)

  local need = 0
  for i = 1, #TABS do
    local key = TABS[i].key
    local page = CreateFrame("Frame", nil, list)
    page:SetPoint("TOPLEFT", list, "TOPLEFT", 1, -1)
    page:SetPoint("TOPRIGHT", list, "TOPRIGHT", -1, -1)
    page:Hide()
    local col = Rows.Column(page)
    local first = #S.cells + 1
    Pages[key](col)
    S.tabCells[key] = { first, #S.cells }
    local h = -col.y + LIST_PAD
    page:SetHeight(h)
    S.pages[key], S.cols[key], S.pageH[key] = page, col, h
    if h + 2 > need then need = h + 2 end
  end
  S.listNeed = need

  S.refresh[#S.refresh + 1] = State.Inheritance
  S.refresh[#S.refresh + 1] = State.Minimap
  S.refresh[#S.refresh + 1] = State.Memory
  S.refresh[#S.refresh + 1] = State.RowLayout
  S.refresh[#S.refresh + 1] = State.Hidden
  S.refresh[#S.refresh + 1] = State.Arrange
  S.refresh[#S.refresh + 1] = Ctx.PaintExtra
  S.refresh[#S.refresh + 1] = State.Postbox
  -- The Mail tab's window reads the category buttons again on every open:
  -- a group may have been made or renamed meanwhile.
  S.refresh[#S.refresh + 1] = function() S.gridStale = true end

  Footer.Build(frame, list)
  frame:HookScript("OnHide", PanelHide)

  -- Let an active host-UI skin restyle the panel like the main window.
  -- ElvUI's skin has no ApplyWindow, so testing only for that left the
  -- options panel wearing Postbox's gold chrome while Skin.Refresh below
  -- ElvUI-skinned every control inside it. Same expression as
  -- Core/RecipientManager.lua.
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

-- /postbox debug text: what the game itself reports of the texts whose look
-- the headless checks cannot see, in every Postbox window that is shown --
-- one line each (Theme.DescribeText), in the bug report's box to copy. Each
-- caption of a control (a window or options tab, a view plate, a Send tab or
-- Manage Recipients tile, a button) has a line of its own, and so do the
-- options' footer and tiles and the arrange inspector's words; every other
-- text has one line for each look it is drawn in, with how many share it.
-- Built on demand; nothing is kept.
function Panel.ShowTextReport()
  local frame = Build()
  local T = ns.Theme
  if not (T and T.DescribeText) then return end
  local lines = {}
  local skin = ns.Skin
  local function Ask(fn)
    local f = skin and skin[fn]
    if type(f) ~= "function" then return "-" end
    local ok, v = pcall(f)
    return ok and tostring(v) or "?"
  end
  lines[1] = string.format("Postbox %s | style %s | Mode %s | accent %s | font %s %s | outline %s | halo %s | UI scale %.3f",
    tostring(ns.VERSION), tostring(ns.SkinAppliedBy or "own"), Ask("GetMode"), Ask("GetAccentKey"), Ask("GetFont"),
    Ask("GetTextScale"), Ask("GetOutline"), tostring(T.HaloGeneration and T.HaloGeneration() or "?"),
    UIParent and UIParent:GetEffectiveScale() or 0)
  -- The texts given a line of their own, left out of the looks after.
  local listed = {}
  local function One(fs, where)
    if not fs then return end
    listed[fs] = true
    local line = T.DescribeText(fs, where)
    if line then lines[#lines + 1] = line end
  end
  -- A control's caption: its own text, and no other the control holds.
  local function Caption(parent, region)
    if parent.Text ~= region or listed[region] then return false end
    listed[region] = true
    return true
  end
  local function Rest(_, region) return not listed[region] end
  -- A window: its captions one by one, then its other texts by look.
  local function Window(root, where)
    T.DescribeTexts(root, where, lines, Caption)
    T.DescribeTexts(root, where .. " text", lines, Rest, true)
  end

  local main = ns.MailboxUI and ns.MailboxUI._frame
  if main and main:IsVisible() then
    local state = ns.MailboxUI._state
    local tab = state and state.activeTab
    Window(main, (tab == "send") and "main send" or "main")
  else
    lines[#lines + 1] = "main: not shown"
  end
  if frame:IsVisible() then
    for key, plate in pairs(S.plates) do One(plate.Text, "options tab " .. tostring(key)) end
    local f = S.footer
    if f then
      local foot = { f.resetText, f.bugText, f.newsText, f.version }
      for i = 1, #foot do One(foot[i], "options footer") end
    end
    for i = 1, #S.tiles do
      local tile = S.tiles[i]
      One(tile.Title, "options tile")
      One(tile.Sub, "options tile")
    end
    Window(frame, "options")
  else
    lines[#lines + 1] = "options: not shown"
  end
  -- Postbox's other windows, each where it is shown: Mail Memory, Manage
  -- Recipients, Character Groups and What's new (the bug report window is
  -- where this is written).
  local others = {
    { _G.PostboxMailMemoryFrame, "memory" },
    { _G.PostboxRecipientManagerFrame, "recipients" },
    { _G.PostboxCharacterGroupsFrame, "groups" },
    { _G.PostboxWhatsNewFrame, "news" },
  }
  for i = 1, #others do
    local win, where = others[i][1], others[i][2]
    if win and win.IsVisible and win:IsVisible() then
      Window(win, where)
    else
      lines[#lines + 1] = where .. ": not shown"
    end
  end
  local insp = ns.Arrange and ns.Arrange._insp
  if insp and insp:IsVisible() then
    T.DescribeTexts(insp, "inspector", lines)
  else
    lines[#lines + 1] = "inspector: not shown"
  end
  BugReport.ShowText(frame, table.concat(lines, "\n"))
end

-- The tab the panel shows; kept for the session, so the panel reopens where
-- it was left.
function Panel.SelectTab(key)
  if not S.pages[key] then key = "mail" end
  S.tab = key
  if not S.frame then return end
  -- A row left washed on the page going away would still be washed when
  -- that page came back.
  local washed = S.washed
  if washed and washed.Wash then washed.Wash:Hide() end
  S.washed = nil
  Tabs.Select(key)
  Ctx.Show(key)
  Insp.SetTab(key)
end

-- Re-reads every control from its source of truth. The panel does this on
-- every open anyway; this exists for state that changes WHILE the panel is
-- up -- a reset button, a shift-drag turning a preset into Custom. The
-- inspector keeps what it was showing.
function Panel.RefreshControls()
  local frame = S.frame
  if not (frame and frame:IsShown()) then return end
  Refresh()
  Rows.Fit()
  Tabs.Fit()
  Footer.Fit()
  Layout()
  Ctx.Paint(S.tab)
  Insp.Repaint()
end

-- Arrange columns and buttons: the arrange mode on the Postbox window, the
-- way its own mark beside the cog opens it -- which brings the Mail tab
-- forward first when the Send tab is showing. Called through the mark
-- itself, at click time, so whatever that mark does, this does. Away from
-- a mailbox, the window opens as its preview (MailboxUI.OpenPreview),
-- already arranging. The panel steps out of the way of the rows being
-- arranged.
function Panel.Arrange()
  local toggle = State.ArrangeToggle()
  if not toggle then
    local UI = ns.MailboxUI
    if UI and type(UI.OpenPreview) == "function" and UI.OpenPreview() and S.frame then S.frame:Hide() end
    return
  end
  local AR = ns.Arrange
  local active = AR and AR.host ~= nil and AR.host.toggle == toggle
  if not active and type(toggle.Click) == "function" then toggle:Click("LeftButton") end
  if S.frame then S.frame:Hide() end
end

-- Shown where it is closed, raised where it is open: /postbox, and the
-- page under the game's Settings.
function Panel.Open()
  local frame = S.frame
  if frame and frame:IsShown() then
    frame:Raise()
    return
  end
  Panel.Toggle(nil)
end

-- Where the panel opens: under `anchor` (the cog), else the screen's middle.
local function PlacePanel(frame, anchor)
  frame:ClearAllPoints()
  if anchor then
    frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
end

function Panel.Toggle(anchor)
  local frame = Build()
  if frame:IsShown() then
    frame:Hide()
    return
  end
  -- Counted again when the Send tab is next shown.
  S.sendText = nil
  Refresh()
  PlacePanel(frame, anchor)
  local scale = frame:GetScale()
  frame:Show()
  frame:Raise()
  if ns.Skin and ns.Skin.Refresh then ns.Skin.Refresh(frame) end
  -- Measured after the skin has re-fonted what it re-fonts.
  Rows.Fit()
  Tabs.Fit()
  Footer.Fit()
  Layout()
  -- Fitted to the screen again (its size may have changed since), and put
  -- back where it opens if that moved its scale.
  local T = ns.Theme
  if T and type(T.FitToScreen) == "function" then T.FitToScreen(frame) end
  if frame:GetScale() ~= scale then PlacePanel(frame, anchor) end
  Panel.SelectTab(S.tab)
end
