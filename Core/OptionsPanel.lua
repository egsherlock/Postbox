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
    -- Not what puts it above the options panel, which is FULLSCREEN_DIALOG
    -- strata: 12.x's StaticPopup does not read this. Every show is lifted
    -- (Theme.LiftPopup).
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
local TILE_H, HOST_H = 46, 32
local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"
local GLOW_TGA = "Interface\\AddOns\\Postbox\\Media\\minimap-glow.tga"
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
  { key = "window",  caption = "OPT_WINDOW_HEADING",  square = true },
  { key = "minimap", caption = "OPT_MINIMAP_HEADING", square = true },
  { key = "memory",  caption = "OPT_MEMORY_TITLE",    square = true },
}

-- Everything the panel keeps between calls, on one table.
local S = {
  cells = {},     -- every row, or half-row, the pointer can rest on
  entries = {},   -- every title and text the inspector can show
  groups = {},    -- the group headings, whose rules are measured
  refresh = {},   -- run on every open and after a reset
  idle = {},      -- tab key -> what the inspector says at rest
  pages = {},     -- tab key -> its page of the list
  plates = {},    -- tab key -> its tab
  ctx = {},       -- tab key -> its drawing, once built
  tab = "mail",
  shown = false,  -- the entry the inspector's text zone shows (nil: at rest)
  bodyH = 0,
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
-- Every control keeps the tooltip it has always had, as in every Postbox
-- window. It stands beside the panel, level with the control, on the side
-- with room: over the panel it would cover the inspector, which is saying
-- the same thing.
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
  Tip.Begin(owner, entry.title, entry.text)
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
-- never flashes the tab's text between two rows.
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
    rule:SetColorTexture(1, 1, 1, HAIR_A)
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
    local extra = nil
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

end

-------------------------------------------------------------
-- The inspector's drawings (Ctx)
--
-- One per tab, built the first time its tab is shown and painted every
-- time it is: the Mail tab's character groups tile and a sample mail row
-- that grows with Larger mail rows and wears the quality mark where the
-- setting puts it; the Send tab's recipients tile; the window over a bit
-- of world, at the player's opacity and border; the minimap icon at a size
-- you can judge, wearing its glow, shadow and accent. Drawn here, from the
-- settings, rather than borrowed from the windows they describe: those
-- windows' own code is not the panel's to reach into.
-------------------------------------------------------------
do
  local CTX_TOP = 11

  -- The fixed height of each tab's drawing, and the gap under it.
  function Ctx.Height(key)
    if key == "mail" then return CTX_TOP + TILE_H + 10 end
    if key == "send" then return CTX_TOP + TILE_H + 10 end
    if key == "window" then return S.installedHost and (CTX_TOP + HOST_H + 10) or 0 end
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
    hover:SetColorTexture(1, 1, 1, WASH_A)
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
    if _G.GameFontNormal then name:SetFontObject(_G.GameFontNormal) end
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

  -- The Mail tab: the character groups tile.
  function Ctx.mail(card)
    local f = CreateFrame("Frame", nil, card)
    f:SetPoint("TOPLEFT", card, "TOPLEFT", CTX_X, -CTX_TOP)
    f:SetSize(CTX_W, TILE_H)
    local tile = Ctx.Tile(f, "Interface\\AddOns\\Postbox\\Media\\minimap-mailbag.tga",
      L["GROUPS_TITLE"], S.idle.mail, Ctx.OpenGroups)
    tile:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.Paint = function()
      -- How many groups there are; none reads as the tile's way in.
      local CG = ns.CharacterGroups
      local list = CG and type(CG.List) == "function" and CG.List() or nil
      local n = type(list) == "table" and #list or 0
      Ctx.PaintTile(tile, n > 0 and ns.Plural("OPT_GROUPS_COUNT", n) or L["GROUPS_NEW"])
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

  -- The Window tab: who the look comes from.
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
      host:SetBackdropColor(0, 0, 0, 0.45)
      host:SetBackdropBorderColor(0.17, 0.17, 0.17, 1)
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
    f:SetSize(CTX_W, math.max(1, y))
    f.Paint = function()
      if host then
        if S.badgeGreen then
          host.Dot:SetColorTexture(0.38, 0.80, 0.44, 1)
        else
          -- Neutral grey, not a warning colour: a deliberate choice is not
          -- a fault.
          host.Dot:SetColorTexture(0.54, 0.54, 0.58, 1)
        end
        T.FitText(host.Text, CTX_W - 36, S.idle.window.title, host)
      end
    end
    return f
  end

end

-------------------------------------------------------------
-- Rows
--
-- The list is built from a handful of row kinds, all read the same way: a
-- checkbox, a dropdown, a push button, a pair of checkboxes side by side, a
-- quiet note, a full-width action. Each row, or half-row, is a cell: it
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

  local function CellEnter(self) Rows.Hover(self) end
  local function CellLeave(self) Rows.Unhover(self) end

  -- A control: the inspector for its cell (or its own entry, where it has
  -- one), and its tooltip.
  local function ControlEnter(self)
    local cell = self.__pbCell
    Rows.Hover(cell, self.__pbEntry)
    Tip.Entry(self, self.__pbEntry or cell.entry)
  end

  local function ControlLeave(self)
    GameTooltip:Hide()
    Rows.Unhover(self.__pbCell)
  end

  Rows.ControlEnter, Rows.ControlLeave = ControlEnter, ControlLeave

  -- A row with a tooltip of its own leaving: the tooltip goes with it.
  function Rows.LeaveRow(self)
    GameTooltip:Hide()
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

  function Rows.Column(parent)
    return { frame = parent, y = -LIST_PAD, first = true, cells = {} }
  end

  -- A block of rows in `col` that greys as one: what a feature's switch
  -- governs. Rows.EndBlock closes it and moves `col` past it.
  function Rows.Block(col)
    local frame = CreateFrame("Frame", nil, col.frame)
    frame:SetPoint("TOPLEFT", col.frame, "TOPLEFT", 0, col.y)
    frame:SetPoint("TOPRIGHT", col.frame, "TOPRIGHT", 0, col.y)
    return { frame = frame, y = 0, first = col.first, cells = {}, parent = col }
  end

  function Rows.EndBlock(block)
    local col = block.parent
    block.frame:SetHeight(math.max(1, -block.y))
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
      line:SetColorTexture(1, 1, 1, HAIR_A)
    end
    col.y = col.y - height
    col.first = false
    return row
  end

  -- Makes `cell` (a row, or half of one, `width` wide) a place the pointer
  -- rests: its wash, its name, its entry. Motion only: a click passes on,
  -- so the panel still drags from anywhere on the list.
  function Rows.Cell(col, cell, width, title, text, role)
    local T = ns.Theme
    local wash = cell:CreateTexture(nil, "BACKGROUND")
    wash:SetAllPoints()
    wash:SetColorTexture(1, 1, 1, WASH_A)
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
      if _G.GameFontNormal then row.Name:SetFontObject(_G.GameFontNormal) end
      ns.Theme.SetColor(row.Name, "accent")
    end
    if spec.entryTitle then row.entry.title = spec.entryTitle end
    AddCheck(row, spec)
    return row
  end

  -- Two checkboxes side by side, each a cell of its own.
  function Rows.Pair(col, a, b)
    local row = Rows.New(col, ROW_H)
    local half = ROW_W / 2
    for i = 1, 2 do
      local spec = (i == 1) and a or b
      local cell = CreateFrame("Frame", nil, row)
      cell:SetPoint("TOPLEFT", row, "TOPLEFT", (i - 1) * half, 0)
      cell:SetSize(half, ROW_H)
      Rows.Cell(col, cell, half, spec.title, spec.text)
      AddCheck(cell, spec)
    end
    local mid = row:CreateTexture(nil, "BORDER")
    mid:SetWidth(1)
    mid:SetPoint("TOPLEFT", row, "TOPLEFT", half, 0)
    mid:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", half, 0)
    mid:SetColorTexture(1, 1, 1, HAIR_A)
    return row
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
    })
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

  -- A push button on the right. spec: title, text, caption, onClick.
  function Rows.Button(col, spec)
    local row = Rows.New(col, ROW_H)
    Rows.Cell(col, row, ROW_W, spec.title, spec.text)
    local btn = ns.Theme.CreateButton(nil, row)
    btn:SetHeight(BUTTON_H)
    btn:SetPoint("RIGHT", row, "RIGHT", -CONTROL_R, 0)
    btn:SetText(spec.caption)
    btn:SetScript("OnClick", spec.onClick)
    Wire(btn, row, true)
    row.kind, row.control = "button", btn
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
    return row
  end

  -- A button across the row that does something rather than setting
  -- something, its mark before its caption. spec: title, text, onClick,
  -- onHover(cell), mark.
  function Rows.Action(col, spec)
    local row = Rows.New(col, ROW_H)
    Rows.Cell(col, row, ROW_W, spec.title, spec.text)
    row.Name:Hide()
    local btn = ns.Theme.CreateButton(nil, row)
    btn:SetHeight(BUTTON_H)
    btn:SetPoint("LEFT", row, "LEFT", NAME_X, 0)
    btn:SetPoint("RIGHT", row, "RIGHT", -CONTROL_R, 0)
    btn:SetText(spec.title)
    btn:SetScript("OnClick", spec.onClick)
    Wire(btn, row, true)
    -- On a holder of its own: a skin's button repaint fades the button's
    -- own textures.
    if spec.mark then btn.Mark = Ctx.Mark(ArtHolder(btn), 12) end
    row.kind, row.control, row.button, row.onHover = "action", btn, btn, spec.onHover
    return row
  end

  -- A group's heading: its name and a rule in the accent to the row's end.
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
    local rule = head:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetPoint("LEFT", text, "RIGHT", NAME_GAP, -1)
    T.FillColor(rule, "accentRule")
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

  -- The action's caption and mark, centred as one across its button.
  local function FitAction(cell, inner)
    local T = ns.Theme
    local btn = cell.button
    local fs = btn:GetFontString()
    if not fs then return end
    local mark = btn.Mark
    local lead = mark and (mark.w + 6) or 0
    local room = inner - 24 - lead
    T.FitText(fs, room, cell.nameText, cell)
    fs:SetWidth(math.min(TextW(fs), room))
    fs:ClearAllPoints()
    fs:SetPoint("CENTER", btn, "CENTER", lead / 2, 0)
    if mark then
      mark:ClearAllPoints()
      mark:SetPoint("CENTER", fs, "LEFT", -(6 + mark.w / 2), 0)
    end
  end

  -- Measured on every open, after the skins have had their say about
  -- fonts, and in whatever language the client speaks. The normal case
  -- keeps its look: a name that would reach the dropdown beside it narrows
  -- that toggle, down to DD_MIN_W, and only past that is the name cut short
  -- -- the inspector's title still carries it whole.
  function Rows.Fit()
    local T = ns.Theme
    local cells = S.cells
    for i = 1, #cells do
      local cell = cells[i]
      local kind = cell.kind
      local inner = cell.w - NAME_X - CONTROL_R
      if kind == "action" then
        FitAction(cell, inner)
      elseif kind == "note" then
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
          controlW = T.SizeToText(cell.control, BUTTON_FIT)
        end
        T.FitText(cell.Name, inner - controlW - NAME_GAP, cell.nameText, cell)
      end
    end
    for i = 1, #S.groups do
      local head = S.groups[i]
      head.Rule:SetWidth(math.max(0, ROW_W - NAME_X - CONTROL_R - NAME_GAP - TextW(head.Text)))
      T.FillColor(head.Rule, "accentRule")
    end
  end
end

-------------------------------------------------------------
-- Tabs
--
-- Five house plates, like the window's own segments: the selected one in
-- the accent, the others neutral. Window, Minimap and Mail Memory carry a
-- small square beside their name, the Window badge's dot lifted onto the
-- tab: green for inheriting or on, a grey ring for overriding or off.
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

  function Tabs.Fit()
    for i = 1, #TABS do FitOne(S.plates[TABS[i].key]) end
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
  if not host then
    entry.title, entry.text = L["OPT_STYLE_TITLE"], L["OPT_STYLE_DESC"]
    Tabs.SetSquare("window", nil)
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
    entry.title = L("OPT_STYLE_INHERIT", host)
    entry.text = L("OPT_STYLE_INHERIT_DESC", host)
  elseif stockName then
    S.badgeGreen = true
    entry.title = L("OPT_STYLE_FOLLOW", host)
    entry.text = L("OPT_STYLE_FOLLOW_DESC", host, stockName)
  else
    S.badgeGreen = false
    entry.title = L("OPT_STYLE_OVERRIDE", host)
    entry.text = L("OPT_STYLE_OVERRIDE_DESC", host, host)
  end
  Tabs.SetSquare("window", S.badgeGreen and "on" or "off")
end

-- The window arranging opens over: the Postbox window at a mailbox, else
-- Mail Memory's window where that is open -- each has the mark in its
-- title bar. Nil when neither is on screen.
function State.ArrangeToggle()
  local UI = ns.MailboxUI
  local window = UI and UI._frame
  if window and window:IsShown() and window.ArrangeButton then return window.ArrangeButton end
  local memory = ns.MailMemory
  local mwindow = memory and memory._frame
  if mwindow and mwindow:IsShown() and mwindow.ArrangeButton then return mwindow.ArrangeButton end
  return nil
end

-- The arrange button: live only where there is a window to arrange, and
-- saying why when there is not. Read on every hover, since a mailbox can
-- close under the open panel.
function State.Arrange(cell)
  cell = cell or S.arrangeCell
  if not cell then return end
  local can = State.ArrangeToggle() ~= nil
  cell.entry = can and S.arrangeOn or S.arrangeOff
  local btn = cell.button
  if btn:IsEnabled() ~= can then
    btn:SetEnabled(can)
    ns.Theme.SetColor(cell.Name, can and "accent" or "textDisabled")
  end
  if btn.Mark then
    local T = ns.Theme
    local c = T.Colors[can and "textPrimary" or "textDisabled"]
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

-- The Mail tab: how a row looks, how the tab behaves, and the sound when
-- mail arrives -- which a player looks for with the mail, not under the
-- minimap.
function Pages.mail(col)
  Rows.Group(col, L["OPT_ROWS_HEADING"])
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
    after = Ctx.Repaint,
  })

  -- Where the crafting quality mark goes, in the list, History and the
  -- memory alike: on the corner of the item's icon (the default), after its
  -- name as a chat link has it, both, or nowhere.
  Rows.Dropdown(col, {
    title = L["OPT_QUALITY_TITLE"], text = L["OPT_QUALITY_DESC"],
    items = {
      { id = "icon", name = L["OPT_QUALITY_ICON"] },
      { id = "name", name = L["OPT_QUALITY_NAME"] },
      { id = "both", name = L["OPT_QUALITY_BOTH"] },
      { id = "off",  name = L["OPT_QUALITY_OFF"] },
    },
    get = function() return ns.MailboxUI.GetQualityMark and ns.MailboxUI.GetQualityMark() or "icon" end,
    set = function(id)
      if ns.MailboxUI.SetQualityMark then ns.MailboxUI.SetQualityMark(id) end
      if ns.MailboxUI.RefreshCollectRowLayout then ns.MailboxUI.RefreshCollectRowLayout() end
      if ns.MailMemory and ns.MailMemory.Refresh then ns.MailMemory.Refresh() end
      Ctx.Repaint()
    end,
  })

  -- Which columns a row shows, in what order, and the gold's and the time
  -- left's own choices are arranged in the window itself, where the rows
  -- are (Core/Arrange.lua). This is the way in from here: the same one the
  -- mark beside the cog is.
  local arrange = Rows.Action(col, {
    title = L["OPT_ARRANGE_BUTTON"], text = L["ARRANGE_TIP"],
    onClick = Panel.Arrange, onHover = State.Arrange, mark = true,
  })
  arrange.entry.extra = "arrange"
  S.arrangeCell, S.arrangeOn = arrange, arrange.entry
  S.arrangeOff = Entry(L["OPT_ARRANGE_BUTTON"], L["ARRANGE_TIP"] .. "\n\n" .. L["ERR_OPEN_MAILBOX_LOOT"], "arrange")

  Rows.Group(col, L["OPT_MAILTAB_HEADING"])
  Rows.Check(col, {
    title = L["OPT_TAB_COUNTS_TITLE"], text = L["OPT_TAB_COUNTS_DESC"],
    get = function() return ns.MailboxUI.GetOption("showTabCounts") end,
    set = function(on)
      ns.MailboxUI.SetOption("showTabCounts", on)
      if ns.MailboxUI.RefreshCollectTabCounts then ns.MailboxUI.RefreshCollectTabCounts() end
    end,
  })
  Rows.Check(col, {
    title = L["OPT_CATEGORY_BUTTONS_TITLE"], text = L["OPT_CATEGORY_BUTTONS_DESC"],
    get = function() return ns.MailboxUI.GetOption("showCategoryButtons") end,
    set = function(on)
      ns.MailboxUI.SetOption("showCategoryButtons", on)
      if ns.MailboxUI.RefreshCollectCategoryButtons then ns.MailboxUI.RefreshCollectCategoryButtons() end
    end,
  })
  -- Nothing to refresh: the mapping is read at the moment a row is clicked,
  -- and the row tooltip's hint line is composed on hover from the same
  -- reading. A list rebuild would repaint rows that are already correct.
  Rows.Check(col, {
    title = L["OPT_PREVIEW_CLICK_TITLE"], text = L["OPT_PREVIEW_CLICK_DESC"],
    get = function() return ns.MailboxUI.GetOption("previewOnClick") end,
    set = function(on) ns.MailboxUI.SetOption("previewOnClick", on) end,
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
  -- How far back History goes.
  local dayItems = {}
  for _, days in ipairs({ 7, 14, 21, 30 }) do
    dayItems[#dayItems + 1] = { id = days, name = ns.Plural("OPT_HISTORY_DAYS", days) }
  end
  Rows.Dropdown(col, {
    title = L["OPT_HISTORY_KEEP_TITLE"], text = L["OPT_HISTORY_KEEP_DESC"],
    items = dayItems,
    get = function() return ns.MailboxUI.GetHistoryDays and ns.MailboxUI.GetHistoryDays() or 7 end,
    set = function(id) if ns.MailboxUI.SetHistoryDays then ns.MailboxUI.SetHistoryDays(id) end end,
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

-- The Send tab: the two switches about composing. The address book they
-- draw on is the tile at the top of the inspector; /postbox recipients is
-- the other way in.
function Pages.send(col)
  Rows.Check(col, {
    title = L["OPT_ATTACH_MAIL_TITLE"], text = L["OPT_ATTACH_MAIL_DESC"],
    get = function() return ns.MailboxUI.GetOption("attachFromMail") end,
    set = function(on)
      ns.MailboxUI.SetOption("attachFromMail", on)
      -- Applies to the mailbox that is open right now, not the next one.
      if ns.MailboxUI.RefreshMailTabAttach then ns.MailboxUI.RefreshMailTabAttach() end
    end,
  })
  -- Nothing to refresh: the option is read at the moment a send succeeds.
  Rows.Check(col, {
    title = L["OPT_KEEP_RECIPIENT_TITLE"], text = L["OPT_KEEP_RECIPIENT_DESC"],
    get = function() return ns.MailboxUI.GetOption("keepRecipient") end,
    set = function(on) ns.MailboxUI.SetOption("keepRecipient", on) end,
  })
end

-- The Window tab: where the window opens, then how it is painted.
function Pages.window(col)
  Rows.Check(col, {
    title = L["GRID_TOGGLE_TITLE"], text = L["GRID_TOGGLE_DESC"],
    get = function() return ns.MailboxUI.GetOption("gridDock") end,
    set = function(on)
      ns.MailboxUI.SetOption("gridDock", on)
      if on and ns.MailboxUI._state then ns.MailboxUI._state.freeMoved = false end
      if ns.MailboxUI.ApplyWindowLayout then ns.MailboxUI.ApplyWindowLayout() end
    end,
  })

  -- The style choice. A host UI is offered first and is the default
  -- wherever one is installed, so the familiar answer is the one already
  -- selected -- but it is now an answer rather than a foregone conclusion.
  local host = S.installedHost
  local styleItems = {}
  if host then styleItems[#styleItems + 1] = { id = "host", name = host } end
  styleItems[#styleItems + 1] = { id = "blizzard", name = L["OPT_STYLE_BLIZZARD"] }
  styleItems[#styleItems + 1] = { id = "modern",   name = L["OPT_STYLE_MODERN"] }
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

  -- The chosen style's own controls. Whichever skin claimed the window
  -- answers these; the panel does not know or care which one it is
  -- talking to. A style that publishes no such controls (Blizzard) simply
  -- contributes nothing here.
  local Skin = GetSkin()
  if not Skin then return end
  -- "Leave it alone" means different things to different styles: under a
  -- host it means match that UI, and under Postbox's own it means the
  -- value the skin was authored with.
  local autoName = HostSkinName() and L("OPT_APPEARANCE_MATCH", HostSkinName()) or L["OPT_APPEARANCE_DEFAULT"]
  -- The border rows offer that entry only where it names something. Under
  -- EllesmereUI it cannot: the suite has no window border to match (see
  -- Core/Skin_EllesmereUI.lua), and "Match EllesmereUI" had always drawn
  -- None. There an unset border simply shows as None and its size as the
  -- step it would draw at.
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
    title = L["OPT_BORDER_TITLE"], text = L["OPT_BORDER_DESC"], items = borderItems,
    get = function()
      if borderAuto and Skin.IsBorderDefault and Skin.IsBorderDefault() then return "auto" end
      return Skin.GetBorderStyle()
    end,
    set = function(id)
      if id == "auto" then Skin.ResetBorder() else Skin.SetBorderStyle(id) end
      Ctx.Repaint()
    end,
  })

  local sizeItems = {}
  if borderAuto then sizeItems[1] = { id = "auto", name = autoName } end
  for step = 1, 4 do
    sizeItems[#sizeItems + 1] = { id = step, name = string.format(L["OPT_BORDER_SIZE_STEP"], step) }
  end
  Rows.Dropdown(col, {
    title = L["OPT_BORDER_SIZE_TITLE"], text = L["OPT_BORDER_SIZE_DESC"], items = sizeItems,
    get = function()
      if borderAuto and Skin.IsBorderSizeDefault and Skin.IsBorderSizeDefault() then return "auto" end
      return Skin.GetBorderSize()
    end,
    set = function(id)
      if id == "auto" then Skin.ResetBorderSize() else Skin.SetBorderSize(id) end
      Ctx.Repaint()
    end,
  })

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

  -- The two effects side by side, their two modifiers beneath (Accent
  -- colours the glow, Pulse breathes it).
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
    Effect("OPT_MINIMAP_SHADOW_TITLE", "OPT_MINIMAP_SHADOW_DESC", "GetShadow", "SetShadow"))
  Rows.Pair(block,
    Effect("OPT_MINIMAP_ACCENT_TITLE", "OPT_MINIMAP_ACCENT_DESC", "GetAccentTint", "SetAccentTint"),
    Effect("OPT_MINIMAP_PULSE_TITLE", "OPT_MINIMAP_PULSE_DESC", "GetPulse", "SetPulse"))

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
    -- leads: it is where the stock indicator lives and the fresh-install
    -- default.
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
    Rows.Button(block, {
      title = L["OPT_MINIMAP_RESET_POS"], text = L["OPT_MINIMAP_RESET_POS_DESC"], caption = L["BTN_RESET"],
      onClick = function()
        if ns.MinimapButton then ns.MinimapButton.ResetPosition() end
        -- The reset just rewrote position AND detachment; the dropdown and
        -- the checkbox above must say so immediately, not on the panel's
        -- next open.
        Panel.RefreshControls()
      end,
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
  row:SetScript("OnEnter", function(self)
    Rows.Hover(self)
    local tip = Tip.Begin(self, self.entry.title, self.entry.text)
    local lines = self.lines
    if #lines > 0 then
      tip:AddLine(" ")
      for i = 1, #lines do tip:AddLine(lines[i], 1, 1, 1) end
      if self.moreLine then tip:AddLine(self.moreLine, 0.6, 0.6, 0.63) end
    end
    Tip.Show(self)
  end)
  row:SetScript("OnLeave", Rows.LeaveRow)
  S.hiddenRow = row
  Rows.EndBlock(block)
end

-------------------------------------------------------------
-- The footer
--
-- What this build is, the one door out to a bug report, and Reset to
-- defaults at the band's left end. Unchanged in behaviour; it sits under
-- the list and the inspector.
-------------------------------------------------------------
-- One of the theme's glyphs, white like the band's text beside it, or nil
-- where the theme has none: the band then reads as words alone.
function Footer.Glyph(parent, name, size)
  local T = ns.Theme
  local glyph = T and type(T.Glyph) == "function" and T.Glyph(parent, name, size, "ARTWORK") or nil
  if glyph then T.SetColor(glyph, "textPrimary") end
  return glyph
end

function Footer.Build(frame, above)
  local statusBand = CreateFrame("Button", nil, frame, "BackdropTemplate")
  statusBand:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -BODY_GAP)
  statusBand:SetPoint("RIGHT", frame, "RIGHT", -EDGE, 0)
  statusBand:SetHeight(BAND_H)
  ns.Theme.ApplyBand(statusBand)

  local statusText = ns.Theme.CreateText(statusBand, "bodySmall")
  statusText:SetJustifyH("CENTER")
  statusText:SetWordWrap(false)
  -- Says what the click does. The band has always opened the bug report;
  -- nothing on it ever said so.
  statusText:SetText(L["OPT_REPORT_BUG"])
  statusText:SetAlpha(0.85)
  -- Its mark before it, the pair centred as one.
  local bugArt = ArtHolder(statusBand)
  local bug = Footer.Glyph(bugArt, "bug", 12)
  statusText:SetPoint("CENTER", statusBand, "CENTER", bug and 8 or 0, 0)
  if bug then
    bug:SetPoint("CENTER", statusText, "LEFT", -11, 0)
    bug:SetAlpha(0.85)
  end

  -- The packager stamps the release TAG into the TOC, which already carries
  -- its own "v" -- do not add another.
  local versionText = ns.Theme.CreateText(statusBand, "bodySmall")
  versionText:SetPoint("RIGHT", statusBand, "RIGHT", -8, 0)
  versionText:SetJustifyH("RIGHT")
  versionText:SetText(tostring(ns.VERSION or ""))
  versionText:SetAlpha(0.55)

  -- Reset to defaults, at the band's left end across from the version: the
  -- one control here that undoes the player's own choices, so it is as
  -- quiet as the version until pointed at, and it asks first -- the dialog
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
          preferredIndex = 3,
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
          preferredIndex = 3,
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
    -- As wide as what it says, re-measured on every open: a host skin can
    -- re-font it after the panel is built.
    local function FitReset()
      reset:SetWidth(math.ceil(resetText:GetStringWidth() or 0) + (arrow and 21 or 4) + (caret and 18 or 4))
    end
    FitReset()
    S.refresh[#S.refresh + 1] = FitReset

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

-- The list and the inspector are one height, so the panel never jumps as
-- the tabs change: the tallest page of rows.
local function Layout()
  local need = math.ceil(S.listNeed or 0)
  if need ~= S.bodyH then
    S.bodyH = need
    S.body:SetHeight(need)
    S.list:SetHeight(need)
    S.insp:SetHeight(need)
    S.frame:SetHeight(TOP + TAB_H + BODY_GAP + need + BODY_GAP + BAND_H + FOOT_BOTTOM)
  end
end

-- The pointer left the list and the inspector from somewhere no row is.
local function BodyLeave(self)
  if self:IsMouseOver() then return end
  local washed = S.washed
  if washed and washed.Wash then washed.Wash:Hide() end
  S.washed = nil
  Insp.Show(nil)
end

-- Closing stops everything the panel set moving.
local function PanelHide()
  local washed = S.washed
  if washed and washed.Wash then washed.Wash:Hide() end
  S.washed = nil
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
    S.pages[key] = page
    if h + 2 > need then need = h + 2 end
  end
  S.listNeed = need

  S.refresh[#S.refresh + 1] = State.Inheritance
  S.refresh[#S.refresh + 1] = State.Minimap
  S.refresh[#S.refresh + 1] = State.Memory
  S.refresh[#S.refresh + 1] = State.Hidden
  S.refresh[#S.refresh + 1] = State.Arrange

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
  Layout()
  Ctx.Paint(S.tab)
  Insp.Repaint()
end

-- Arrange columns and buttons: the arrange mode on the Postbox window, the
-- way its own mark beside the cog opens it -- which brings the Mail tab
-- forward first when the Send tab is showing. Called through the mark
-- itself, at click time, so whatever that mark does, this does. The panel
-- steps out of the way of the rows being arranged.
function Panel.Arrange()
  local toggle = State.ArrangeToggle()
  if not toggle then
    State.Arrange()
    return
  end
  local AR = ns.Arrange
  local active = AR and AR.host ~= nil and AR.host.toggle == toggle
  if not active and type(toggle.Click) == "function" then toggle:Click("LeftButton") end
  if S.frame then S.frame:Hide() end
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
  frame:ClearAllPoints()
  if anchor then
    frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
  frame:Show()
  frame:Raise()
  if ns.Skin and ns.Skin.Refresh then ns.Skin.Refresh(frame) end
  -- Measured after the skin has re-fonted what it re-fonts.
  Rows.Fit()
  Tabs.Fit()
  Layout()
  Panel.SelectTab(S.tab)
end
