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
    box:SetFontObject(T.FontObject("bodySmall") or GameFontHighlightSmall)
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
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(type(title) == "function" and title(self) or title)
      GameTooltip:AddLine(type(desc) == "function" and desc(self) or desc, 1, 1, 1, true)
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
    if type(build) == "function" then ok, text = pcall(build) end
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
  function BugReport.Toggle(panel)
    if not win then
      win = Build()
      if panel then panel:HookScript("OnHide", function() win:Hide() end) end
      -- The same expression as the options panel and the groups editor.
      local applyWindow = ns.Skin and (ns.Skin.ApplyWindow or ns.Skin.Apply)
      if applyWindow then applyWindow(win) end
    end
    if win:IsShown() then
      win:Hide()
      return
    end
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
-- A dropdown's toggle, and the narrowest a long translated name may squeeze
-- it to before the name itself is cut short.
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
local TILE_H, HOST_H, SWATCH_H, STAGE, STAGE_ICON, SAMPLE_MAX, MOCK_H = 46, 32, 74, 104, 54, 50, 34
-- The Postbox style's small window, and the accent row's reading under it.
local MINI_H, READOUT_LINES = 128, 3
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
  plates = {},    -- tab key -> its tab
  ctx = {},       -- tab key -> its drawing, once built
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

function Tip.Begin(owner, title, text)
  local tip = GameTooltip
  tip:SetOwner(owner, "ANCHOR_NONE")
  tip:SetText(title or "")
  if text and text ~= "" then tip:AddLine(text, 1, 1, 1, true) end
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
  Tip.Begin(owner, entry.title, ns.Summary(entry.text))
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
    measure:Hide()
    S.measure = measure
  end

  -- entry, or nil for the tab's own text.
  function Insp.Show(entry)
    if entry == S.shown then return end
    S.shown = entry
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
    if h < SAY_MIN then h = SAY_MIN end
    if S.bodyH > 0 and h > S.bodyH then h = S.bodyH end
    say:SetHeight(h)
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
      if h < SAY_MIN then h = SAY_MIN end
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
  -- to cut one.
  function Insp.Need(entry, extraH)
    ns.Summary(entry.text)
    return Lay(S.measure, entry.title, entry.text, extraH)
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
-- time it is: the Mail tab's character groups tile and sample mail rows
-- that grow with Larger mail rows, line their gold up as Row layout says
-- and wear the quality mark where the setting puts it; the Send tab's
-- recipients tile; the window over a bit of world, at the player's
-- opacity and border; the minimap icon at a size you can judge, wearing
-- its glow, shadow and accent. Drawn here, from the settings, rather than
-- borrowed from the windows they describe: those windows' own code is not
-- the panel's to reach into.
-------------------------------------------------------------
do
  local CTX_TOP = 11
  -- Sample mail: a tiered reagent, whose link carries a quality mark --
  -- bought for SAMPLE_PRICE and, on the second row, sold for SAMPLE_SALE,
  -- the gold coming with a coin for its icon.
  local SAMPLE_ITEM = 191462
  -- The stack it came in, on its icon (Stack counts on item icons).
  local SAMPLE_COUNT = "20"
  local SAMPLE_DAYS = 29
  local SAMPLE_PRICE, SAMPLE_SALE = 522600, 13090000
  local SAMPLE_COIN = "Interface\\Icons\\INV_Misc_Coin_01"
  -- The step between the sample's figure columns, as Mail Memory's rows.
  local SAMPLE_GAP = 6

  -- The fixed height of each tab's drawing, and the gap under it.
  function Ctx.Height(key)
    if key == "mail" then return CTX_TOP + TILE_H + 8 + SAMPLE_MAX + 10 end
    if key == "send" then return CTX_TOP + TILE_H + 10 end
    if key == "window" then
      local skin = GetSkin()
      local h = (skin and skin.IsPostboxStyle and not skin.IsCreativeStyle) and MINI_H or SWATCH_H
      return CTX_TOP + (S.installedHost and (HOST_H + 8) or 0) + h + 10
    end
    if key == "minimap" then return CTX_TOP + 4 + STAGE + 10 end
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
    tile.titleText, tile.entry = title, entry
    TintChevron(tile, false)
    tile:SetScript("OnEnter", SpotEnter)
    tile:SetScript("OnLeave", SpotLeave)
    tile:SetScript("OnClick", onClick)
    return tile
  end

  function Ctx.PaintTile(tile, fact)
    local T = ns.Theme
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

  ---------------------------------------------------------
  -- The sample mail rows
  --
  -- A small drawing of the list, from the settings rather than from the
  -- list's own code. One-line rows: two mails, the sample item bought --
  -- its price and its slot -- and the same item sold, gold and no slot, so
  -- Row layout visibly moves the sale's gold: under the other gold in
  -- Columns, out at the edge under the slot Packed. Their figures stand
  -- in the list's default order, gold then slots. Under Larger mail rows,
  -- the first mail alone on two lines with a larger icon, where it came from
  -- and how long it has left under its name: those rows have no columns.
  -- The quality mark on the icon's corner or not, and beside the name:
  -- before it -- where both names then start after its room, as every row
  -- of the list keeps it -- after it, always whole, or neither. The slot as
  -- the Slots choice writes it.
  ---------------------------------------------------------

  -- A drawing's own inset ground and edge, from the palette (dark: black at
  -- 45% edged #2b2b2b; the light palette's own on a light one).
  local function PaintPlain(frame)
    local C = ns.Theme.Colors
    local f, e = C.inset, C.insetEdge
    frame:SetBackdropColor(f[1], f[2], f[3], f[4])
    frame:SetBackdropBorderColor(e[1], e[2], e[3], e[4])
  end
  Ctx.PaintPlain = PaintPlain

  -- A figure of the sample's, right-aligned in its column.
  local function SampleFigure(art)
    local fs = ns.Theme.CreateText(art, "secondary")
    fs:SetJustifyH("RIGHT")
    fs:SetWordWrap(false)
    return fs
  end

  -- fs, its column's right edge and width, and the row's middle.
  local function PlaceFigure(s, fs, right, width, y)
    fs:ClearAllPoints()
    fs:SetPoint("RIGHT", s, "TOPLEFT", right, y)
    fs:SetWidth(width)
    fs:Show()
  end

  -- The sample item's name, link and quality, asked for once if the client
  -- has not loaded it yet; the row repaints when it arrives.
  local function SampleItem()
    local info = C_Item and C_Item.GetItemInfo
    local name, link, quality
    if type(info) == "function" then name, link, quality = info(SAMPLE_ITEM) end
    if not name and not S.sampleAsked then
      S.sampleAsked = true
      local item = type(Item) == "table" and type(Item.CreateFromItemID) == "function"
        and Item:CreateFromItemID(SAMPLE_ITEM) or nil
      if item and item.ContinueOnItemLoad then
        item:ContinueOnItemLoad(function()
          local f = S.ctx.mail
          if f and f:IsVisible() and f.Paint then f.Paint() end
        end)
      end
    end
    return name, link, quality
  end

  function Ctx.Sample(parent)
    local T = ns.Theme
    local s = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    s:SetBackdrop(PLAIN_BACKDROP)
    PaintPlain(s)
    s:SetWidth(CTX_W)
    local art = ArtHolder(s)
    -- For the mark before the name, made the first time it is drawn.
    s.Art = art
    s.IconEdge = art:CreateTexture(nil, "ARTWORK", nil, 0)
    s.Icon = art:CreateTexture(nil, "ARTWORK", nil, 1)
    s.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    s.IconEdge:SetPoint("TOPLEFT", s.Icon, "TOPLEFT", -1, 1)
    s.IconEdge:SetPoint("BOTTOMRIGHT", s.Icon, "BOTTOMRIGHT", 1, -1)
    -- The mark over the icon's corner, a level above, with a soft dark copy
    -- behind it so it reads on light item art.
    local over = CreateFrame("Frame", nil, s)
    over:SetAllPoints(s)
    over:SetFrameLevel(art:GetFrameLevel() + 1)
    s.MarkShadow = over:CreateTexture(nil, "ARTWORK")
    s.MarkShadow:SetAlpha(0.6)
    s.Mark = over:CreateTexture(nil, "OVERLAY")
    -- The stack's count in the opposite corner, as the list writes it.
    s.Count = over:CreateFontString(nil, "OVERLAY")
    s.Count:SetJustifyH("RIGHT")
    s.Count:SetWordWrap(false)
    s.Name = T.CreateText(art, "value")
    s.Name:SetJustifyH("LEFT")
    s.Name:SetWordWrap(false)
    s.Line2 = T.CreateText(art, "secondary")
    s.Line2:SetJustifyH("LEFT")
    s.Line2:SetWordWrap(false)
    -- The second mail: a stripe, as the list's rows alternate, its coin and
    -- its name; and the figures of both.
    s.Stripe = art:CreateTexture(nil, "BACKGROUND", nil, 1)
    T.FillChrome(s.Stripe, 0.035)
    s.Icon2 = art:CreateTexture(nil, "ARTWORK", nil, 1)
    s.Icon2:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    s.Icon2:SetTexture(SAMPLE_COIN)
    s.Name2 = T.CreateText(art, "value")
    s.Name2:SetJustifyH("LEFT")
    s.Name2:SetWordWrap(false)
    s.Gold, s.Slots, s.Gold2 = SampleFigure(art), SampleFigure(art), SampleFigure(art)
    -- Behind both golds while Row layout is pointed at: the column the
    -- choice moves, washed as the arrange mode washes one.
    s.Wash = art:CreateTexture(nil, "BACKGROUND", nil, 3)
    s.Wash2 = art:CreateTexture(nil, "BACKGROUND", nil, 3)
    s.Wash:Hide()
    s.Wash2:Hide()
    return s
  end

  -- The golds' wash, while the pointer is on Row layout (its row or its
  -- dropdown) and the sample has columns to show.
  function Ctx.PaintSampleWash(s)
    s = s or S.sample
    if not s then return end
    local cell = S.lanesCell
    -- Pointed at, or holding the panel with its list open (Rows.Hold).
    local held = S.held
    local on = s.Gold:IsShown() and cell ~= nil
      and (held == cell or (held == nil and cell:IsMouseOver())) or false
    if on then
      local r, g, b = ns.Theme.GetAccent()
      for i = 1, 2 do
        local wash, fs = (i == 1) and s.Wash or s.Wash2, (i == 1) and s.Gold or s.Gold2
        wash:SetColorTexture(r, g, b, 0.22)
        wash:ClearAllPoints()
        wash:SetPoint("TOPLEFT", fs, "TOPLEFT", -3, 2)
        wash:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 3, -2)
      end
    end
    s.Wash:SetShown(on)
    s.Wash2:SetShown(on)
  end

  function Ctx.PaintSample(s)
    local T = ns.Theme
    local UI = ns.MailboxUI
    local larger = UI and not UI.GetOption("compactRows") or false
    PaintPlain(s)
    local onIcon = not (UI and type(UI.GetQualityIcon) == "function") or UI.GetQualityIcon()
    local byName = UI and type(UI.GetQualityName) == "function" and UI.GetQualityName() or "off"
    local iconSize = larger and 24 or 18
    local lineH = larger and 30 or 24
    s:SetHeight(larger and (lineH + 16 + 2) or (2 * lineH + 2))

    local name, link, quality = SampleItem()
    local icon = C_Item and type(C_Item.GetItemIconByID) == "function" and C_Item.GetItemIconByID(SAMPLE_ITEM) or nil
    s.Icon:SetTexture(icon or 134400)
    s.Icon:SetSize(iconSize, iconSize)
    s.Icon:ClearAllPoints()
    s.Icon:SetPoint("CENTER", s, "TOPLEFT", 8 + iconSize / 2, -(1 + lineH / 2))
    local r, g, b = 1, 1, 1
    if quality and C_Item and type(C_Item.GetItemQualityColor) == "function" then
      local qr, qg, qb = C_Item.GetItemQualityColor(quality)
      if qr then r, g, b = qr, qg, qb end
    end
    s.IconEdge:SetColorTexture(r * 0.6, g * 0.6, b * 0.6, 1)

    -- The mark the link carries, as the list reads it.
    local mark = type(link) == "string" and (link:match("|A:Professions%-[^|]*|a")
      or link:match("|A:[^|]*[Qq]uality[^|]*|a")) or nil
    local atlas = mark and mark:match("|A:([^:|]+)") or nil
    local R0 = ns.CollectTab and ns.CollectTab.RowRules
    if atlas and onIcon and R0 and R0.ShowMark and R0.PlaceMark then
      -- The list's own art, size and place (RowRules): the icon's top-left
      -- corner, by the one rule every item icon follows.
      R0.ShowMark(s.Mark, s.MarkShadow, atlas)
      R0.PlaceMark(s.Mark, s.MarkShadow, s.Icon, iconSize)
    else
      s.Mark:Hide()
      s.MarkShadow:Hide()
    end
    -- The count, where Stack counts on item icons puts it: the list's font,
    -- size and corner.
    if UI and UI.GetOption("iconCounts") then
      local object = T.FontObject("numberSmall")
      local path = object and object:GetFont()
      s.Count:SetFont(path or STANDARD_TEXT_FONT, larger and 12 or 10, "OUTLINE")
      s.Count:SetTextColor(1, 1, 1, 1)
      s.Count:ClearAllPoints()
      if larger then
        s.Count:SetPoint("BOTTOMRIGHT", s.Icon, "BOTTOMRIGHT", -2, 1)
      else
        s.Count:SetPoint("BOTTOMRIGHT", s.Icon, "BOTTOMRIGHT", 2, -1)
      end
      s.Count:SetText(SAMPLE_COUNT)
      s.Count:Show()
    else
      s.Count:Hide()
    end

    local text = name or ""
    -- After the name: the list's own marked name (RowRules.WithMark), fitted
    -- by the list's own rule, the mark whole and the name shortened before
    -- it where they do not both fit (RowRules.FitSubject).
    local R = ns.CollectTab and ns.CollectTab.RowRules
    if mark and name and byName == "after" then
      text = (R and R.WithMark) and R.WithMark(name, mark) or (name .. " " .. mark)
    end
    local function FitName(width)
      if R and R.FitSubject then
        R.FitSubject(s, s.Name, width, text, s.Art)
      else
        T.FitText(s.Name, width, text)
      end
    end
    -- Before the name: the mark where the name began, and the room for it
    -- before both names (the list's own, RowRules.NameMarkRoom).
    local room = (byName == "before" and R and R.NameMarkRoom) and R.NameMarkRoom() or 0
    T.SetTextRGB(s.Name, T.InkFor(r, g, b))
    s.Name:ClearAllPoints()
    s.Name:SetPoint("LEFT", s.Icon, "RIGHT", 7 + room, 0)
    if R and R.PaintNameMark then R.PaintNameMark(s, name and mark or nil, s.Art, s.Name) end
    if not S.sampleMeta then
      S.sampleMeta = L["ROW_AH_BOUGHT"] .. "  \194\183  " .. ns.Helpers.TimeLeft(SAMPLE_DAYS)
    end
    local nameX = 8 + iconSize + 7
    s.Stripe:SetShown(not larger)
    s.Icon2:SetShown(not larger)
    s.Name2:SetShown(not larger)
    if larger then
      s.Gold:Hide()
      s.Slots:Hide()
      s.Gold2:Hide()
      s.Line2:ClearAllPoints()
      s.Line2:SetPoint("TOPLEFT", s, "TOPLEFT", nameX, -(1 + lineH - 3))
      T.FitText(s.Line2, CTX_W - nameX - 8, S.sampleMeta)
      s.Line2:Show()
      FitName(CTX_W - nameX - 8 - room)
    else
      s.Line2:Hide()
      -- The figures, made once: the price, the slot, the sale's gold.
      local fig = S.sampleFigures
      if not fig then
        local F = ns.Core and ns.Core.Formatting
        local money = F and F.FormatMoneyCompact
        fig = { money and money(SAMPLE_PRICE, true) or "52g", ns.Plural("COUNT_SLOTS", 1),
          money and money(SAMPLE_SALE, true) or "1309g" }
        S.sampleFigures = fig
      end
      s.Gold:SetText(fig[1])
      -- The slot as the Slots column's choice writes it: "1 slot", or "1".
      local number = UI and type(UI.GetSlotsStyle) == "function" and UI.GetSlotsStyle() == "number"
      s.Slots:SetText(number and "1" or fig[2])
      s.Gold2:SetText(fig[3])
      T.SetColor(s.Gold, "negative")
      T.SetColor(s.Slots, "textSecondary")
      T.SetColor(s.Gold2, "positive")
      -- Each column as wide as its widest entry, gold then slots from the
      -- edge in. In Columns, the sale's gold stands in the gold column;
      -- Packed, at the edge, where the slot it does not have would be.
      local goldW = math.max(TextW(s.Gold), TextW(s.Gold2))
      -- The number alone stands in a column as narrow as the list draws one.
      local slotsW = math.max(TextW(s.Slots), (R and R.FIGURE_MIN) or 0)
      local edge = CTX_W - 8
      local goldEdge = edge - slotsW - SAMPLE_GAP
      local lined = not (UI and UI.GetRowPacking) or UI.GetRowPacking() ~= "packed"
      local saleEdge = lined and goldEdge or edge
      local y1, y2 = -(1 + lineH / 2), -(1 + lineH + lineH / 2)
      PlaceFigure(s, s.Slots, edge, slotsW, y1)
      PlaceFigure(s, s.Gold, goldEdge, goldW, y1)
      PlaceFigure(s, s.Gold2, saleEdge, goldW, y2)
      FitName(math.max(40, goldEdge - goldW - SAMPLE_GAP - nameX - room))

      s.Stripe:ClearAllPoints()
      s.Stripe:SetPoint("TOPLEFT", s, "TOPLEFT", 1, -(1 + lineH))
      s.Stripe:SetPoint("BOTTOMRIGHT", s, "BOTTOMRIGHT", -1, 1)
      s.Icon2:SetSize(iconSize, iconSize)
      s.Icon2:ClearAllPoints()
      s.Icon2:SetPoint("CENTER", s, "TOPLEFT", 8 + iconSize / 2, y2)
      s.Name2:ClearAllPoints()
      s.Name2:SetPoint("LEFT", s.Icon2, "RIGHT", 7 + room, 0)
      T.FitText(s.Name2, math.max(40, saleEdge - goldW - SAMPLE_GAP - nameX - room), name or "")
    end
    Ctx.PaintSampleWash(s)
  end

  -- The Mail tab: the character groups tile and the sample row.
  function Ctx.mail(card)
    local f = CreateFrame("Frame", nil, card)
    f:SetPoint("TOPLEFT", card, "TOPLEFT", CTX_X, -CTX_TOP)
    f:SetSize(CTX_W, TILE_H + 8 + SAMPLE_MAX)
    local tile = Ctx.Tile(f, "Interface\\AddOns\\Postbox\\Media\\minimap-mailbag.tga",
      L["GROUPS_TITLE"], S.idle.mail, Ctx.OpenGroups)
    tile:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    local sample = Ctx.Sample(f)
    sample:SetPoint("TOPLEFT", tile, "BOTTOMLEFT", 0, -8)
    S.sample = sample
    f.Paint = function()
      -- How many groups there are; none reads as the tile's way in.
      local CG = ns.CharacterGroups
      local list = CG and type(CG.List) == "function" and CG.List() or nil
      local n = type(list) == "table" and #list or 0
      Ctx.PaintTile(tile, n > 0 and ns.Plural("OPT_GROUPS_COUNT", n) or L["GROUPS_NEW"])
      Ctx.PaintSample(sample)
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
  -- The window over a bit of world
  --
  -- Its fill in the host's colour at the player's opacity, its border at
  -- the chosen weight, and what it holds, which stays solid at every
  -- opacity: the rule the real window keeps.
  ---------------------------------------------------------
  function Ctx.Swatch(parent)
    local sw = CreateFrame("Frame", nil, parent)
    sw:SetSize(CTX_W, SWATCH_H)
    -- The world is drawn on a frame of its own inside the swatch, which
    -- clips it: the patches of light reach past the swatch's edge.
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

    local win = CreateFrame("Frame", nil, sw)
    win:SetFrameLevel(world:GetFrameLevel() + 1)
    win:SetPoint("TOPLEFT", sw, "TOPLEFT", 34, -10)
    win:SetPoint("BOTTOMRIGHT", sw, "BOTTOMRIGHT", -34, 10)
    win.Fill = win:CreateTexture(nil, "BACKGROUND")
    win.Fill:SetAllPoints()
    win.Edges = {}
    for i = 1, 4 do win.Edges[i] = win:CreateTexture(nil, "BORDER") end
    local title = win:CreateTexture(nil, "ARTWORK")
    title:SetSize(69, 5)
    title:SetPoint("TOP", win, "TOP", 0, -6)
    title:SetColorTexture(0.91, 0.91, 0.91, 0.8)
    for i = 1, 3 do
      local row = win:CreateTexture(nil, "ARTWORK")
      row:SetHeight(7)
      row:SetPoint("TOPLEFT", win, "TOPLEFT", 7, -(17 + (i - 1) * 12))
      row:SetPoint("TOPRIGHT", win, "TOPRIGHT", -7, -(17 + (i - 1) * 12))
      if i == 2 then win.Selected = row else row:SetColorTexture(1, 1, 1, 0.10) end
    end
    sw.Win = win
    return sw
  end

  function Ctx.PaintSwatch(sw)
    local T = ns.Theme
    local win = sw.Win
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

    -- The border: none, or a line as thick as its size step. Match is the
    -- edge of the windows beside Postbox: one unit in their edge's colour, or
    -- the one-unit light edge where that edge is the host's own frame. A skin
    -- with no border of its own to choose (ElvUI) draws its one-unit edge; a
    -- stock window wears Blizzard's frame.
    local size, a = 0, 0
    local er, eg, eb = 1, 1, 1
    if skin then
      local style = type(skin.GetBorderStyle) == "function" and skin.GetBorderStyle() or "none"
      if style == "match" and type(skin.GetEdge) == "function" then
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
    local e = win.Edges
    for i = 1, 4 do
      e[i]:ClearAllPoints()
      e[i]:SetColorTexture(er, eg, eb, a)
      e[i]:SetShown(size > 0)
    end
    if size > 0 then
      e[1]:SetPoint("TOPLEFT", win, "TOPLEFT", 0, 0)
      e[1]:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, 0)
      e[1]:SetHeight(size)
      e[2]:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 0, 0)
      e[2]:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", 0, 0)
      e[2]:SetHeight(size)
      e[3]:SetPoint("TOPLEFT", win, "TOPLEFT", 0, -size)
      e[3]:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 0, size)
      e[3]:SetWidth(size)
      e[4]:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, -size)
      e[4]:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", 0, size)
      e[4]:SetWidth(size)
    end
    local ar, ag, ab = T.GetAccent()
    win.Selected:SetColorTexture(ar, ag, ab, 0.22)
  end

  ---------------------------------------------------------
  -- The Postbox style's window, small
  --
  -- Under the Postbox style the Window tab's drawing is a window of that
  -- style over the same bit of world, painted from its live palette: the
  -- fill at the player's opacity, the tint and the strip, the keyline in its
  -- weight and colour, the sheen, a lit tab over an idle one, a heading and
  -- its rule, two striped rows with their figures, a button's caption and a
  -- ticked box. Every row of the style's groups shows in it as it changes;
  -- its text wears the style's own fonts, so face, size and outline do too.
  ---------------------------------------------------------
  local MINI_PAD_X, MINI_PAD_Y, MINI_STRIP, MINI_ROW = 12, 9, 12, 16

  -- Four lines of the addon's white tile round `frame`, `inset` in.
  local function MiniEdges(frame, layer, sub)
    local e = {}
    for i = 1, 4 do e[i] = frame:CreateTexture(nil, layer, nil, sub) end
    return e
  end

  local function LayEdges(e, frame, inset, w)
    for i = 1, 4 do e[i]:ClearAllPoints() end
    e[1]:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
    e[1]:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset, -inset)
    e[1]:SetHeight(w)
    e[2]:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", inset, inset)
    e[2]:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
    e[2]:SetHeight(w)
    e[3]:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
    e[3]:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", inset, inset)
    e[3]:SetWidth(w)
    e[4]:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset, -inset)
    e[4]:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
    e[4]:SetWidth(w)
  end

  local function TintEdges(e, c, shown)
    for i = 1, 4 do
      e[i]:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
      e[i]:SetShown(shown ~= false)
    end
  end

  -- A block: a fill and a one-unit edge.
  local function MiniBlock(parent)
    local b = CreateFrame("Frame", nil, parent)
    b.Fill = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.Fill:SetAllPoints()
    b.Edges = MiniEdges(b, "BORDER", 1)
    LayEdges(b.Edges, b, 0, 1)
    return b
  end

  local function PaintBlock(b, fill, edge)
    b.Fill:SetColorTexture(fill[1], fill[2], fill[3], fill[4] or 1)
    TintEdges(b.Edges, edge)
  end

  function Ctx.Mini(parent)
    local T = ns.Theme
    local sw = Ctx.Swatch(parent)
    sw:SetHeight(MINI_H)
    -- The swatch's own little window gives way to the style's.
    sw.Win:Hide()
    local win = CreateFrame("Frame", nil, sw)
    win:SetFrameLevel(sw.Win:GetFrameLevel())
    win:SetPoint("TOPLEFT", sw, "TOPLEFT", MINI_PAD_X, -MINI_PAD_Y)
    win:SetPoint("BOTTOMRIGHT", sw, "BOTTOMRIGHT", -MINI_PAD_X, MINI_PAD_Y)
    win.Fill = win:CreateTexture(nil, "BACKGROUND", nil, -8)
    win.Fill:SetAllPoints()
    win.Strip = win:CreateTexture(nil, "BACKGROUND", nil, -7)
    win.Strip:SetPoint("TOPLEFT", win, "TOPLEFT", 0, 0)
    win.Strip:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, 0)
    win.Strip:SetHeight(MINI_STRIP)
    win.Sheen = win:CreateTexture(nil, "BACKGROUND", nil, -6)
    win.Sheen:SetTexture(WHITE)
    win.Sheen:SetPoint("TOPLEFT", win, "TOPLEFT", 0, 0)
    win.Sheen:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, 0)
    win.Sheen:SetHeight(40)
    win.Outer = MiniEdges(win, "BORDER", 6)
    win.Inner = MiniEdges(win, "BORDER", 7)
    win.Title = T.CreateText(win, "bodySmall")
    win.Title:SetPoint("CENTER", win.Strip, "CENTER", 0, 0)
    win.Title:SetText(L["FRAME_TITLE"])

    -- A lit tab and an idle one, the window's own plates.
    win.Tabs = {}
    for i = 1, 2 do
      local plate = T.CreatePlate(win, "tab")
      plate:SetHeight(16)
      plate:SetWidth(62)
      plate:SetPoint("TOPLEFT", win, "TOPLEFT", 6 + (i - 1) * 66, -(MINI_STRIP + 4))
      plate:EnableMouse(false)
      plate:SetText(L[i == 1 and "TAB_COLLECT" or "TAB_SEND"])
      if plate.Text then plate.Text:SetFontObject(T.FontObject("bodySmall")) end
      local skin = ns.Skin
      if skin and skin.StyleTabPlate then skin.StyleTabPlate(plate) end
      T.SetPlateSelected(plate, i == 1)
      win.Tabs[i] = plate
    end

    win.Head = T.CreateText(win, "heading")
    win.Head:SetPoint("TOPLEFT", win, "TOPLEFT", 7, -(MINI_STRIP + 25))
    win.Head:SetText(L["OPT_GROUP_COLORS"])
    win.Rule = win:CreateTexture(nil, "ARTWORK")
    win.Rule:SetHeight(1)
    win.Rule:SetPoint("LEFT", win.Head, "RIGHT", 6, 0)
    win.Rule:SetPoint("RIGHT", win, "RIGHT", -7, 0)

    -- The list and its two rows.
    local list = MiniBlock(win)
    list:SetPoint("TOPLEFT", win, "TOPLEFT", 6, -(MINI_STRIP + 40))
    list:SetPoint("TOPRIGHT", win, "TOPRIGHT", -6, -(MINI_STRIP + 40))
    list:SetHeight(2 * MINI_ROW + 2)
    list.Rows = {}
    for i = 1, 2 do
      local row = list:CreateTexture(nil, "BACKGROUND", nil, 2)
      row:SetPoint("TOPLEFT", list, "TOPLEFT", 1, -1 - (i - 1) * MINI_ROW)
      row:SetPoint("TOPRIGHT", list, "TOPRIGHT", -1, -1 - (i - 1) * MINI_ROW)
      row:SetHeight(MINI_ROW)
      local name = T.CreateText(list, "bodySmall")
      name:SetPoint("LEFT", row, "LEFT", 5, 0)
      name:SetText(i == 1 and L["ROW_AH_BOUGHT"] or L["TAB_COLLECT"])
      local fig = T.CreateText(list, "bodySmall")
      fig:SetPoint("RIGHT", row, "RIGHT", -5, 0)
      fig:SetText(i == 1 and "-52g" or "+1309g")
      list.Rows[i] = { stripe = row, name = name, fig = fig }
    end
    win.List = list

    local button = MiniBlock(win)
    button:SetSize(70, 16)
    button:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -6)
    button.Text = T.CreateText(button, "bodySmall")
    button.Text:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.Text:SetText(L["BTN_TAKE_ALL"])
    win.Button = button

    local box = MiniBlock(win)
    box:SetSize(12, 12)
    box:SetPoint("TOPRIGHT", list, "BOTTOMRIGHT", 0, -8)
    box.Tick = T.Glyph and T.Glyph(box, "check", 8, "OVERLAY") or nil
    if box.Tick then box.Tick:SetPoint("CENTER", box, "CENTER", 0, 0) end
    win.Box = box

    sw.Mini = win
    return sw
  end

  function Ctx.PaintMini(sw)
    local T = ns.Theme
    local skin = GetSkin()
    local win = sw.Mini
    local P = skin and skin.Palette
    if not (win and P) then return end
    local C = T.Colors
    local alpha = skin.GetBgOpacity()
    local fill = P.window
    win.Fill:SetColorTexture(fill[1], fill[2], fill[3], alpha)
    local s = P.strip
    win.Strip:SetColorTexture(s[1], s[2], s[3], s[4] * alpha)
    local sheen = skin.GetSheen and skin.GetSheen()
    local sc = P.sheen
    if sheen and win.Sheen.SetGradient and type(CreateColor) == "function" then
      if not win.SheenLo then win.SheenLo, win.SheenHi = CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0) end
      win.SheenLo:SetRGBA(sc[1], sc[2], sc[3], 0)
      win.SheenHi:SetRGBA(sc[1], sc[2], sc[3], sc[4])
      win.Sheen:SetGradient("VERTICAL", win.SheenLo, win.SheenHi)
    end
    win.Sheen:SetShown(sheen and true or false)
    local border = skin.GetBorderStyle()
    local show = border ~= "none"
    LayEdges(win.Outer, win, 0, 1)
    LayEdges(win.Inner, win, 1, border == "thick" and 2 or 1)
    TintEdges(win.Outer, P.keyOuter, show)
    TintEdges(win.Inner, P.inner, show)
    local t = P.title
    win.Title:SetTextColor(t[1], t[2], t[3], t[4])
    for i = 1, 2 do T.SetPlateSelected(win.Tabs[i], i == 1) end
    T.FillColor(win.Rule, "accentRule")
    PaintBlock(win.List, P.list, P.listEdge)
    local stripes = { C.stripeOdd, C.stripeEven }
    for i = 1, 2 do
      local row = win.List.Rows[i]
      local c = stripes[i]
      row.stripe:SetColorTexture(c[1], c[2], c[3], c[4])
      T.SetColor(row.fig, i == 1 and "negative" or "positive")
    end
    PaintBlock(win.Button, P.button, P.buttonEdge)
    if skin.ButtonTextRGB then
      T.SetTextRGB(win.Button.Text, skin.ButtonTextRGB())
    end
    PaintBlock(win.Box, P.check, P.checkEdge)
    if win.Box.Tick then win.Box.Tick:SetVertexColor(T.GetAccentTone("mark")) end
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
    local skin = GetSkin()
    local mini = skin and skin.IsPostboxStyle and not skin.IsCreativeStyle and true or false
    local sw = mini and Ctx.Mini(f) or Ctx.Swatch(f)
    sw:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y)
    f:SetSize(CTX_W, y + (mini and MINI_H or SWATCH_H))
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
      if mini then Ctx.PaintMini(sw) else Ctx.PaintSwatch(sw) end
    end
    return f
  end

  ---------------------------------------------------------
  -- The minimap icon at a size you can judge
  --
  -- On a quiet ground roughly a minimap's own average value, so both glow
  -- and shadow read the way they will in the world, WEARING the live
  -- settings: accent tint, glow (with its pulse) and shadow render here as
  -- they will on the minimap. Faded, and still, while the icon is off.
  ---------------------------------------------------------
  function Ctx.minimap(card)
    local f = CreateFrame("Frame", nil, card)
    f:SetPoint("TOPLEFT", card, "TOPLEFT", CTX_X, -CTX_TOP)
    f:SetSize(CTX_W, 4 + STAGE)
    local stage = CreateFrame("Frame", nil, f)
    stage:SetSize(STAGE, STAGE)
    stage:SetPoint("TOP", f, "TOP", 0, -4)
    -- Clipped, with its art on a holder inside it: the glow reaches past
    -- the stage's edge.
    if stage.SetClipsChildren then stage:SetClipsChildren(true) end
    local art = ArtHolder(stage)
    local ground = art:CreateTexture(nil, "BACKGROUND", nil, -7)
    ground:SetAllPoints()
    ground:SetColorTexture(0.40, 0.41, 0.38, 1)
    local shadow = art:CreateTexture(nil, "BACKGROUND", nil, -1)
    shadow:SetPoint("CENTER", stage, "CENTER", 0, -1)
    shadow:SetTexture(GLOW_TGA)
    shadow:SetVertexColor(0, 0, 0)
    shadow:SetAlpha(0.9)
    shadow:SetSize(STAGE_ICON * 1.8, STAGE_ICON * 1.8)
    local glow = art:CreateTexture(nil, "BACKGROUND", nil, 0)
    glow:SetPoint("CENTER", stage, "CENTER", 0, 0)
    glow:SetTexture(GLOW_TGA)
    glow:SetBlendMode("ADD")
    glow:SetSize(STAGE_ICON * 2.2, STAGE_ICON * 2.2)
    local pulse = glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.55)
    fade:SetDuration(1.6)
    fade:SetSmoothing("IN_OUT")
    local icon = art:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER", stage, "CENTER", 0, 0)

    f.Stop = function() pulse:Stop() end
    f.Paint = function()
      local Icon = ns.MinimapButton
      local on = Icon and Icon.GetEnabled and Icon.GetEnabled() and true or false
      stage:SetAlpha(on and 1 or 0.4)
      local spec = Icon and Icon.GetIconSpec and Icon.GetIconSpec()
      if not spec then
        icon:Hide()
        glow:Hide()
        shadow:Hide()
        pulse:Stop()
        return
      end
      icon:Show()
      if spec.atlas then icon:SetAtlas(spec.atlas) else icon:SetTexture(spec.texture) end
      icon:SetSize(STAGE_ICON, STAGE_ICON * (spec.aspect or 1))
      icon:SetDesaturated(not on)
      local r, g, b = 1, 1, 1
      local accentOn = Icon.GetAccentTint and Icon.GetAccentTint()
      if accentOn then r, g, b = ns.Theme.GetAccent() end
      if spec.tintable and accentOn then icon:SetVertexColor(r, g, b) else icon:SetVertexColor(1, 1, 1) end
      glow:SetVertexColor(r, g, b)
      if Icon.GetGlow and Icon.GetGlow() then
        glow:Show()
        -- A switched-off icon does not keep moving.
        if on and (not Icon.GetPulse or Icon.GetPulse()) then
          if not pulse:IsPlaying() then pulse:Play() end
        else
          pulse:Stop()
        end
      else
        pulse:Stop()
        glow:Hide()
      end
      shadow:SetShown(Icon.GetShadow and Icon.GetShadow() or false)
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
    if cell == S.lanesCell then Ctx.PaintSampleWash() end
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

  -- A block of rows in `col` that greys as one: what a feature's switch
  -- governs. Rows.EndBlock closes it and moves `col` past it.
  function Rows.Block(col)
    local frame = CreateFrame("Frame", nil, col.frame)
    frame:SetPoint("TOPLEFT", col.frame, "TOPLEFT", 0, col.y)
    frame:SetPoint("TOPRIGHT", col.frame, "TOPRIGHT", 0, col.y)
    local block = { frame = frame, y = 0, top = 0, first = col.first, cells = {}, items = {}, parent = col }
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
    return block
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
    row.Name:SetAlpha(0.78)
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
    col.y = col.y - GROUP_H
    col.first = true
    return head
  end

  -- Greyed in colour and alpha together, and not clickable; its motion
  -- scripts stay, so the inspector and the tooltip still say what it does.
  function Rows.SetEnabled(cell, on)
    local control = cell.control
    if control and control.SetEnabled then control:SetEnabled(on) end
    local more = cell.more
    if more and more.SetEnabled then more:SetEnabled(on) end
    if cell.kind ~= "note" and cell.Name then
      ns.Theme.SetColor(cell.Name, on and "accent" or "textDisabled")
    end
  end

  function Rows.SetBlock(block, on)
    if not block then return end
    block.frame:SetAlpha(on and 1 or 0.4)
    for i = 1, #block.cells do Rows.SetEnabled(block.cells[i], on) end
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
  -- fonts, and in whatever language the client speaks. The normal case
  -- keeps its look: a pair whose name will not fit its half comes apart
  -- (Rows.FitPairs); a name that would reach the dropdown beside it narrows
  -- that toggle, down to DD_MIN_W, and only past that is the name cut short
  -- -- the inspector's title still carries it whole.
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
          local want = DD_W
          local nameW = TextW(cell.Name)
          if nameW + NAME_GAP + DD_W > inner then
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
      T.FillColor(head.Rule, "accent")
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
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:SetText(self.__pbOverflowText)
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
  Tabs.SetSquare("minimap", on and "on" or "off")
  Ctx.Paint("minimap")
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
  for i = 1, #list do
    local who = list[i]
    names[i] = (Memory and Memory.ClassName) and Memory.ClassName(who.realm, who.name) or who.name
  end
  for i = #lines, 1, -1 do lines[i] = nil end
  local shown = math.min(#names, 12)
  for i = 1, shown do lines[i] = names[i] end
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
  -- rows are placed again where they stand; the sample rows show the sale's
  -- gold move, and while the choice is pointed at, where the gold stands.
  -- Under the way into arranging and over Larger mail rows: how a row's
  -- figures stand, then how tall the row is.
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
  local function PaintWash() Ctx.PaintSampleWash() end
  lanes:HookScript("OnEnter", PaintWash)
  lanes:HookScript("OnLeave", PaintWash)
  lanes.control:HookScript("OnEnter", PaintWash)
  lanes.control:HookScript("OnLeave", PaintWash)

  -- Compact is the default, so the switch is the one a player turns ON to
  -- change it: larger, two-line rows. The stored option is still
  -- compactRows, read inverted, so nobody's choice moves.
  Rows.Check(col, {
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

  -- The crafting quality mark, in the list, History and the memory alike,
  -- is two things a player sets apart: the badge on the corner of the
  -- item's icon (on by default), and a mark beside the name -- before it,
  -- with the names kept in line, after it as a chat link has it, or none
  -- (the default). Every list's rows are drawn again, and the sample's,
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
  -- the whole panel taller. Either redraws the rows the same way.
  Rows.Pair(col, {
    title = L["OPT_QUALITY_ICON_TITLE"], text = L["OPT_QUALITY_ICON_DESC"],
    get = function() return not ns.MailboxUI.GetQualityIcon or ns.MailboxUI.GetQualityIcon() end,
    set = function(on)
      if ns.MailboxUI.SetQualityIcon then ns.MailboxUI.SetQualityIcon(on) end
      QualityChanged()
    end,
  }, {
    title = L["OPT_ICON_COUNTS_TITLE"], text = L["OPT_ICON_COUNTS_DESC"],
    get = function() return ns.MailboxUI.GetOption("iconCounts") end,
    set = function(on)
      ns.MailboxUI.SetOption("iconCounts", on)
      QualityChanged()
    end,
  })
  Rows.Dropdown(col, {
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
  Rows.Pair(col, {
    title = L["OPT_CATEGORY_BUTTONS_TITLE"], text = L["OPT_CATEGORY_BUTTONS_DESC"],
    get = function() return ns.MailboxUI.GetOption("showCategoryButtons") end,
    set = function(on)
      ns.MailboxUI.SetOption("showCategoryButtons", on)
      if ns.MailboxUI.RefreshCollectCategoryButtons then ns.MailboxUI.RefreshCollectCategoryButtons() end
    end,
  }, {
    title = L["OPT_TOTALS_TITLE"], text = L["OPT_TOTALS_DESC"],
    get = function() return ns.MailboxUI.GetOption("showTotals") end,
    set = function(on)
      ns.MailboxUI.SetOption("showTotals", on)
      if ns.MailboxUI.RefreshCollectCategoryButtons then ns.MailboxUI.RefreshCollectCategoryButtons() end
    end,
  })
  Rows.Check(col, {
    title = L["OPT_TAB_COUNTS_TITLE"], text = L["OPT_TAB_COUNTS_DESC"],
    get = function() return ns.MailboxUI.GetOption("showTabCounts") end,
    set = function(on)
      ns.MailboxUI.SetOption("showTabCounts", on)
      if ns.MailboxUI.RefreshCollectTabCounts then ns.MailboxUI.RefreshCollectTabCounts() end
      -- Mail Memory's header counts its box under the same switch.
      if ns.MailMemory and ns.MailMemory.Refresh then ns.MailMemory.Refresh() end
    end,
  })
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
    Rows.Dropdown(col, {
      title = L["OPT_TAB_INDICATOR_TITLE"], text = L["OPT_TAB_INDICATOR_DESC"],
      items = {
        { id = "dot",    name = Caption("dot") },
        { id = "before", name = Caption("before") },
        { id = "none",   name = Caption("none") },
      },
      get = function() return UI.GetTabIndicator and UI.GetTabIndicator() or "dot" end,
      set = function(id) if UI.SetTabIndicator then UI.SetTabIndicator(id) end end,
    })
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
  Rows.Dropdown(col, {
    title = L["OPT_READ_MAIL_TITLE"], text = L["OPT_READ_MAIL_DESC"],
    items = {
      { id = "fold",   name = L["OPT_READ_FOLD"] },
      { id = "tab",    name = L["OPT_READ_TAB"] },
      { id = "delete", name = L["OPT_READ_DELETE"] },
    },
    get = function() return ns.MailboxUI.GetReadMode and ns.MailboxUI.GetReadMode() or "fold" end,
    set = function(id) if ns.MailboxUI.SetReadMode then ns.MailboxUI.SetReadMode(id) end end,
  })
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
  Rows.Dropdown(col, {
    title = L["OPT_STYLE_TITLE"], text = L["OPT_STYLE_DESC"], items = styleItems,
    get = function() return ns.MailboxUI.GetStyleChoice and ns.MailboxUI.GetStyleChoice() end,
    set = function(id)
      if ns.MailboxUI.SetStyleChoice then ns.MailboxUI.SetStyleChoice(id) end
      -- The style is claimed once at login, so the choice needs a reload
      -- to take. A dialog with the reload in it beats a chat line telling
      -- the player to go and type one -- and Later is a real answer: the
      -- setting is already saved either way.
      if EnsureStyleDialog() then
        ns.Theme.LiftPopup(StaticPopup_Show(POPUP_STYLE_RELOAD))
      else
        ns.Print(L["MSG_STYLE_RELOAD"])
      end
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
-- (Mode, the accent, the background colour, opacity, the tint), Edges and
-- rows (the border, its colour, the corners, row stripes and the sheen side
-- by side), Text (font, size, outline, button captions). The drawing at the
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
    local surfaces = WithoutCustom(Skin.GetSurfaceChoices(), Skin)
    S.pbSurfaceCell = Rows.Dropdown(col, {
      title = L["OPT_SURFACE_TITLE"], text = L["OPT_SURFACE_DESC"], items = Items(surfaces),
      swatchFor = Swatches(surfaces, "surface", Skin),
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
    Rows.Dropdown(col, {
      title = L["OPT_TINT_TITLE"], text = L["OPT_TINT_DESC"], items = Items(Skin.GetTintChoices()),
      get = function() return Skin.GetTint() end,
      set = function(id)
        Skin.SetTint(id)
        Ctx.Repaint()
      end,
    })

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
    Rows.Dropdown(col, {
      title = L["OPT_OUTLINE_TITLE"], text = L["OPT_OUTLINE_DESC"], items = Items(Skin.GetOutlineChoices()),
      get = function() return Skin.GetOutline() end,
      set = function(id) Skin.SetOutline(id) Ctx.Repaint() end,
    })
    Rows.Dropdown(col, {
      title = L["OPT_BUTTON_TEXT_TITLE"], text = L["OPT_BUTTON_TEXT_DESC"], items = Items(Skin.GetButtonTextChoices()),
      get = function() return Skin.GetButtonText() end,
      set = function(id) Skin.SetButtonText(id) Ctx.Repaint() end,
    })
  end
end

-- Under the Postbox style: the background colour is Dark mode's, so its row
-- greys in Light; the opacity row shows the value in force (Light keeps 85%
-- or more).
function State.Postbox()
  local cell = S.pbSurfaceCell
  local skin = GetSkin()
  if not (cell and skin and skin.GetMode) then return end
  Rows.SetEnabled(cell, skin.GetMode() ~= "light")
  if S.pbOpacityCell then Rows.PaintDropdown(S.pbOpacityCell) end
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

-- The Minimap tab (Core/MinimapButton.lua): the switch, then everything
-- about the icon, then the flash that is drawn on it. Resolved at click
-- time like every other binding, so the page stays honest if the module is
-- absent.
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

  local block = Rows.Block(col)
  S.minimapBlock = block

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

  -- The glow and its pulse side by side, the one breathing the other; then
  -- the accent's tint, on the glow and the icon, beside the shadow.
  local function Effect(titleKey, descKey, get, set)
    return {
      title = L[titleKey], text = L[descKey],
      get = function() return ns.MinimapButton and ns.MinimapButton[get]() end,
      set = function(on) if ns.MinimapButton then ns.MinimapButton[set](on) end end,
      after = Ctx.Repaint,
    }
  end
  Rows.Pair(block,
    Effect("OPT_MINIMAP_GLOW_TITLE", "OPT_MINIMAP_GLOW_DESC", "GetGlow", "SetGlow"),
    Effect("OPT_MINIMAP_PULSE_TITLE", "OPT_MINIMAP_PULSE_DESC", "GetPulse", "SetPulse"))
  Rows.Pair(block,
    Effect("OPT_MINIMAP_ACCENT_TITLE", "OPT_MINIMAP_ACCENT_DESC", "GetAccentTint", "SetAccentTint"),
    Effect("OPT_MINIMAP_SHADOW_TITLE", "OPT_MINIMAP_SHADOW_DESC", "GetShadow", "SetShadow"))

  if hostStyled then
    -- One quiet line, not a paragraph: the whole of it is in the inspector.
    Rows.Note(block, L["OPT_MINIMAP_EUI_SHORT"], L["OPT_MINIMAP_EUI_SHORT"], L["OPT_MINIMAP_EUI_STYLED"])
  else
    local sizeItems = {}
    for _, px in ipairs({ 16, 20, 24, 28 }) do
      sizeItems[#sizeItems + 1] = { id = px, name = string.format(L["OPT_MINIMAP_SIZE_STEP"], px) }
    end
    Rows.Dropdown(block, {
      title = L["OPT_MINIMAP_SIZE_TITLE"], text = L["OPT_MINIMAP_SIZE_DESC"], items = sizeItems,
      get = function() return ns.MinimapButton and ns.MinimapButton.GetIconSize() end,
      set = function(id) if ns.MinimapButton then ns.MinimapButton.SetIconSize(id) end end,
    })
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

  -- The flash is drawn on the icon, so with the icon off it has nothing to
  -- draw on: it greys with the rows above.
  Rows.Check(block, {
    title = L["OPT_ALERT_FLASH_TITLE"], text = L["OPT_ALERT_FLASH_DESC"],
    get = function() return ns.MinimapButton and ns.MinimapButton.GetAlertFlash() end,
    set = function(on) if ns.MinimapButton then ns.MinimapButton.SetAlertFlash(on) end end,
  })
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
    local lines = self.lines
    if #lines > 0 then
      tip:AddLine(" ")
      for i = 1, #lines do tip:AddLine(lines[i], 1, 1, 1) end
      if self.moreLine then tip:AddLine(self.moreLine, 0.6, 0.6, 0.63) end
    end
    Tip.Show(self)
  end
  row:SetScript("OnEnter", HiddenEnter)
  row:SetScript("OnLeave", Rows.LeaveRow)
  S.hiddenRow = row
  Rows.EndBlock(block)
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

  local statusText = T.CreateText(statusBand, "bodySmall")
  statusText:SetJustifyH("LEFT")
  statusText:SetWordWrap(false)
  -- Says what the click does. The band has always opened the bug report;
  -- nothing on it ever said so.
  statusText:SetText(L["OPT_REPORT_BUG"])
  statusText:SetAlpha(0.85)
  -- Its mark before it.
  local bugArt = ArtHolder(statusBand)
  local bug = Footer.Glyph(bugArt, "bug", 12)
  if bug then
    bug:SetPoint("CENTER", statusText, "LEFT", -11, 0)
    bug:SetAlpha(0.85)
  end

  -- What's new? (Core/WhatsNew.lua), at the band's right end, as quiet as
  -- Report a bug: a button of its own laid over the band, as Reset to
  -- defaults is, so a click on it is never also the bug report's.
  local news = CreateFrame("Button", nil, statusBand)
  news:SetFrameLevel(statusBand:GetFrameLevel() + 2)
  news:SetPoint("TOPRIGHT", statusBand, "TOPRIGHT", -8, 0)
  news:SetPoint("BOTTOMRIGHT", statusBand, "BOTTOMRIGHT", -8, 0)
  local newsText = T.CreateText(news, "bodySmall")
  newsText:SetPoint("RIGHT", news, "RIGHT", 0, 0)
  newsText:SetJustifyH("RIGHT")
  newsText:SetWordWrap(false)
  newsText:SetText(L["WHATSNEW_TITLE"])
  newsText:SetAlpha(0.85)
  news:SetScript("OnClick", function()
    local News = ns.WhatsNew
    if News and type(News.Toggle) == "function" then News.Toggle(frame, true) end
  end)
  news:SetScript("OnEnter", function() newsText:SetAlpha(1) end)
  news:SetScript("OnLeave", function() newsText:SetAlpha(0.85) end)

  -- The version, under the band's right end in the game's smallest face (in
  -- the host's where it has one), dim. Only words: What's new? above it is
  -- the door. The packager stamps the release TAG into the TOC, which
  -- already carries its own "v" -- do not add another.
  local versionText = T.CreateText(frame, "secondary")
  local tiny = _G.GameFontWhiteTiny
  if tiny then
    versionText:SetFontObject(T.HostFont(tiny))
    T.SetColor(versionText, "textSecondary")
  end
  versionText:SetPoint("TOPRIGHT", statusBand, "BOTTOMRIGHT", -8, -Footer.VERSION_GAP)
  versionText:SetJustifyH("RIGHT")
  versionText:SetWordWrap(false)
  versionText:SetText(tostring(ns.VERSION or ""))
  versionText:SetAlpha(0.55)

  S.footer = {
    band = statusBand, bugText = statusText, bugMark = bug and 17 or 0,
    news = news, newsText = newsText, version = versionText,
  }

  -- Reset to defaults, at the band's left end across from What's new?: the
  -- one control here that undoes the player's own choices, so it is quiet
  -- until pointed at, and it asks first -- the dialog
  -- says what goes and what stays. A button of its own laid over the band,
  -- so a click on it is never also a click on the bug report.
  --
  -- Two resets, offered side by side: the settings alone, or everything
  -- Postbox keeps but the list of the player's characters. The second
  -- clears what the player built -- recipients, groups, Mail Memory,
  -- History -- so it is the dialog's last button, kept apart from the first
  -- by Cancel, and it only asks again: nothing is cleared until a second
  -- dialog, which says it cannot be undone, is answered. Enter answers
  -- neither dialog (no enterClicksFirstButton); Escape and Cancel close
  -- both without a change.
  do
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
      if styleChanged then
        if EnsureStyleDialog() then
          ns.Theme.LiftPopup(StaticPopup_Show(POPUP_STYLE_RELOAD))
        else
          ns.Print(L["MSG_STYLE_RELOAD"])
        end
      end
    end

    -- Neither reset runs while Postbox is collecting or sending (MailboxUI,
    -- UI.ResetBlockedBy): true, and a line in chat saying what to wait for.
    -- Asked at the footer's click and again at every answer, since a run can
    -- start while a dialog stands; a refused answer closes its dialog.
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

    local function ResetEverythingNow()
      local UI = ns.MailboxUI
      if Busy() or not (UI and type(UI.ResetEverything) == "function") then return end
      local styleChanged, refused = UI.ResetEverything()
      if refused then return end
      AfterReset(styleChanged)
      ns.Print(L["MSG_RESET_ALL_DONE"])
    end

    -- The second question, a frame after the first dialog has closed, so it
    -- opens where the first one was rather than stacked under it.
    local function AskEverything()
      if Busy() then return end
      local function Show()
        ns.Theme.LiftPopup(StaticPopup_Show(POPUP_RESET_ALL, L["MSG_RESET_ALL_CONFIRM"]))
      end
      if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
        C_Timer.After(0, Show)
      else
        Show()
      end
    end

    -- Registered on first use, like the reload offer. No popup, no reset:
    -- this never happens without the question being asked.
    local function EnsureResetDialog()
      if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then
        return false
      end
      if not StaticPopupDialogs[POPUP_RESET] then
        StaticPopupDialogs[POPUP_RESET] = {
          text = "%s",
          button1 = L["BTN_RESET_SETTINGS"],
          button2 = L["COD_CONFIRM_CANCEL"],
          button3 = L["BTN_RESET_EVERYTHING"],
          OnAccept = ResetSettingsNow,
          OnAlt = AskEverything,
          timeout = 0,
          whileDead = true,
          hideOnEscape = true,
          showAlert = true,
          -- Its text describes both choices, so it takes the popup's wider
          -- width; so does the second, for the same length of text.
          wideText = true,
        }
      end
      if not StaticPopupDialogs[POPUP_RESET_ALL] then
        StaticPopupDialogs[POPUP_RESET_ALL] = {
          text = "%s",
          button1 = L["BTN_RESET"],
          button2 = L["COD_CONFIRM_CANCEL"],
          OnAccept = ResetEverythingNow,
          timeout = 0,
          whileDead = true,
          hideOnEscape = true,
          showAlert = true,
          wideText = true,
        }
      end
      return true
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
    if arrow then arrow:SetPoint("CENTER", reset, "LEFT", 10, 0) end
    if caret then caret:SetPoint("CENTER", resetText, "RIGHT", 9, 0) end
    local function Quiet(on)
      local a = on and 0.55 or 1
      resetText:SetAlpha(a)
      if arrow then arrow:SetAlpha(a) end
      if caret then caret:SetAlpha(a) end
    end
    Quiet(true)
    -- As wide as what it says, re-measured on every open (Footer.Fit): a
    -- host skin can re-font it after the panel is built.
    S.footer.FitReset = function()
      local width = math.ceil(resetText:GetStringWidth() or 0) + (arrow and 21 or 4) + (caret and 18 or 4)
      reset:SetWidth(width)
      return width
    end

    reset:SetScript("OnClick", function()
      if Busy() then return end
      if EnsureResetDialog() then
        ns.Theme.LiftPopup(StaticPopup_Show(POPUP_RESET, L["MSG_RESET_CONFIRM"]))
      end
    end)
    reset:SetScript("OnEnter", function(self)
      Quiet(false)
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
    statusText:SetAlpha(1)
    if bug then bug:SetAlpha(1) end
    Tip.Begin(self, L["OPT_BUG_TIP_TITLE"], L["OPT_BUG_TIP_DESC"])
    Tip.Show(self)
  end)
  statusBand:SetScript("OnLeave", function()
    statusText:SetAlpha(0.85)
    if bug then bug:SetAlpha(0.85) end
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
    local entries = S.entries
    for i = 1, #entries do
      local entry = entries[i]
      local h = Insp.Need(entry, entry.extra and Ctx.ExtraHeight(entry.extra) or 0)
      if h > text then text = h end
    end
    for i = 1, #TABS do
      local key = TABS[i].key
      local ctxH = Ctx.Height(key)
      local entry = S.idle[key]
      if entry and ctxH > 0 then
        local h = Insp.Need(entry, 0)
        if h < SAY_MIN then h = SAY_MIN end
        if ctxH + h > text then text = ctxH + h end
      end
    end
    S.textNeed = text
  end
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
    Pages[key](col)
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
