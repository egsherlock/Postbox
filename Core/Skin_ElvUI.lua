local _, ns = ...

-- =====================================================================
-- Postbox :: ElvUI skin (optional, auto-applied)
-- ---------------------------------------------------------------------
-- This file is a no-op unless ElvUI is installed and loaded. It restyles
-- the Postbox window to match ElvUI's look, and — if ElvUI_WindTools is
-- present — adds its shadow/glow border. Everything is guarded with pcall
-- so a future ElvUI API change can never break Postbox itself; at worst
-- the addon falls back to its own built-in theme.
-- =====================================================================

local E = _G.ElvUI and _G.ElvUI[1]
if not E then return end

local S = E:GetModule("Skins", true)
if not S then return end

local Skin = {}

-- ------------------------------------------------------------------
-- WindTools shadow (optional). Falls back to ElvUI's native shadow.
-- ------------------------------------------------------------------
local function GetWindToolsSkins()
  local WT = _G.WindTools and _G.WindTools[1]
  if not WT then return nil end
  local mod = WT.Modules and WT.Modules.Skins
  if mod and mod.CreateShadow then return mod end
  return nil
end

local function AddShadow(frame)
  if not frame then return end
  local WTS = GetWindToolsSkins()
  if WTS then
    pcall(function() WTS:CreateShadow(frame) end)
  elseif frame.CreateShadow then
    pcall(function() frame:CreateShadow() end)
  end
end

-- ------------------------------------------------------------------
-- Guarded element handlers
-- ------------------------------------------------------------------
local function HandleEditBox(e)
  if e and not e.__postboxSkinned then
    e.__postboxSkinned = true
    pcall(function() S:HandleEditBox(e) end)
  end
end

local function HandleButton(b)
  -- Only Postbox's own push-buttons (tagged by ns.Theme.CreateButton); never
  -- mail rows, attachment slots, or icon-only buttons.
  if b and b.__postboxButton and not b.__postboxSkinned then
    b.__postboxSkinned = true
    pcall(function() S:HandleButton(b, true) end)
  end
end

-- Checkboxes carry __postboxCheck (set by the options panel, the recipient
-- manager and the compose screen's C.O.D. toggle) and their caption is reachable
-- as __label. EllesmereUI has always styled both; ElvUI styled neither, because
-- a CheckButton reaching the generic Button branch below is discarded for want
-- of __postboxButton.
local function HandleCheck(c)
  if not c or c.__postboxSkinned then return end
  c.__postboxSkinned = true
  if S.HandleCheckBox then
    pcall(function() S:HandleCheckBox(c) end)
  end
end

local function HandleScroll(sf)
  if not sf then return end
  local name = sf.GetName and sf:GetName()
  local sb = sf.ScrollBar or (name and _G[name .. "ScrollBar"])
  if sb and not sb.__postboxSkinned then
    sb.__postboxSkinned = true
    -- ElvUI renamed the helper across versions; try the modern one first.
    if S.HandleScrollBar then
      pcall(function() S:HandleScrollBar(sb) end)
    elseif S.HandleTrimScrollBar then
      pcall(function() S:HandleTrimScrollBar(sb) end)
    end
    -- The addon reserves a wide gutter sized for the classic Blizzard scroll bar;
    -- ElvUI's bar is thinner, so pin it just inside the scroll frame's parent right
    -- edge to stop it overhanging and to keep it off the list content.
    local parent = sf:GetParent()
    if parent then
      pcall(function()
        sb:ClearAllPoints()
        sb:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -18)
        sb:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -4, 18)
      end)
    end
  end
end

local function SkinThemedPanel(panel, template)
  -- Postbox's themed frames (text-field wraps, the mail-list area, the detail
  -- overlay, etc.) carry the addon's golden 'card'/'list' backdrop plus a tiled
  -- rock surface texture. Swap that for an ElvUI template so they read as clean
  -- ElvUI panels — and so the scroll bar sits on a clean background instead of the
  -- rock-textured gutter. Inner editboxes are skipped (see __postboxNoEditSkin) so
  -- the multiline field's backdrop can't grow with the text.
  if not panel or panel.__postboxSkinned then return end
  panel.__postboxSkinned = true
  if panel.pbSurfaceTexture then panel.pbSurfaceTexture:SetAlpha(0) end
  pcall(function() panel:StripTextures() end)
  if panel.SetTemplate then pcall(function() panel:SetTemplate(template or "Transparent") end) end
end

-- Recursive pass over content widgets: input-field wraps, edit boxes, scroll
-- bars and the addon's tagged push-buttons. Mail rows / icon buttons are left to
-- the addon's own theme.
local function SkinTree(frame, depth)
  if not frame or depth > 8 then return end
  local kids = { frame:GetChildren() }
  for i = 1, #kids do
    local c = kids[i]
    if c and c.IsObjectType then
      if c.__postboxInputWrap then
        SkinThemedPanel(c, "Default")
      -- The single authority for "this is one of Postbox's themed containers".
      --
      -- This used to probe for the addon's surface texture instead, which made
      -- the set of frames ElvUI skinned a side effect of which frames happened
      -- to get a texture. The two skins therefore disagreed: ElvUI skinned the
      -- type-ahead popup and the compose attachment slots but not the contact
      -- picker; EllesmereUI did the reverse. Core/Theme.lua now sets this key
      -- in the four places -- ApplyList / ApplyCard / ApplyBand / StyleInput --
      -- that are the only routes to a themed surface, so the two skins act on
      -- exactly the same frames. See SPEC-UI 3.3.
      elseif c.__postboxPanel then
        SkinThemedPanel(c, "Transparent")
      elseif c:IsObjectType("EditBox") then
        if not c.__postboxNoEditSkin then HandleEditBox(c) end
      elseif c:IsObjectType("ScrollFrame") then
        HandleScroll(c)
      -- Before the Button branch: a CheckButton *is* a Button, and the generic
      -- branch would drop it. Same order as Skin_EllesmereUI's tree walk.
      elseif c.__postboxCheck then
        HandleCheck(c)
      elseif c:IsObjectType("Button") then
        HandleButton(c)
      end
    end
    SkinTree(c, depth + 1)
  end
end

-- ------------------------------------------------------------------
-- Public entry points (called from Core/MailboxUI.lua)
-- ------------------------------------------------------------------

-- Re-skinnable, idempotent pass for content that can be (re)built while the
-- window is open (e.g. after a mail-list refresh).
function Skin.Refresh(frame)
  if not frame then return end
  pcall(function() SkinTree(frame, 0) end)
  -- The Mail/Read view selector is now a 2-button segmented toggle; its buttons
  -- carry __postboxButton and are skinned by SkinTree above, so nothing extra is
  -- needed here. Nothing in Postbox uses a Blizzard menu (see COMBAT_TAINT.md):
  -- the options panel, the contact picker and the select control are all frames
  -- the addon owns, so they arrive here as ordinary tagged children.
end

-- One-time skin of the main window. Safe to call more than once.
function Skin.Apply(frame)
  if not frame or frame.__postboxSkinned then return end
  frame.__postboxSkinned = true

  -- The shared claim record, read by Core/Skin_EllesmereUI.lua. This pass is
  -- StripTextures + SetTemplate + a shadow, none of which has an undo, so once
  -- it has run on a Postbox window a later EllesmereUI activation cannot take
  -- the window over cleanly -- it can only stand down. Set here rather than in
  -- Claim() because claiming ns.Skin harms nothing; painting is the point of no
  -- return.
  ns.SkinAppliedBy = "elvui"

  -- Hide Postbox's own golden marble/tint so ElvUI's backdrop shows through.
  for _, key in ipairs({ "pbWindowStone", "pbWindowTint" }) do
    if frame[key] then frame[key]:SetAlpha(0) end
  end

  pcall(function() frame:StripTextures() end)
  if frame.SetTemplate then pcall(function() frame:SetTemplate("Transparent") end) end

  -- BasicFrameTemplateWithInset exposes an .Inset child.
  if frame.Inset then
    pcall(function() frame.Inset:StripTextures() end)
    if frame.Inset.SetTemplate then pcall(function() frame.Inset:SetTemplate("Transparent") end) end
  end

  if frame.CloseButton and S.HandleCloseButton then
    pcall(function() S:HandleCloseButton(frame.CloseButton) end)
  end

  -- Tab buttons: prefer the tab handler, fall back to the button handler.
  -- The tabs are flat plates the addon draws itself (Core/Theme.lua), not
  -- Blizzard panel tabs: there is no Left/Middle/Right art for ElvUI to strip
  -- and no PanelTemplates pushed text-shift to undo. All this has to do is
  -- replace the selected-state visual with a flat gold underline accent + gold
  -- text; the widget permanently retires its own plate art as soon as this
  -- override is installed, so nothing here needs to strip it.
  if frame.TabButtons then
    for _, tab in pairs(frame.TabButtons) do
      if tab and not tab.__postboxSkinned then
        tab.__postboxSkinned = true
        local ok = false
        if S.HandleTab then ok = pcall(function() S:HandleTab(tab) end) end
        if not ok and S.HandleButton then pcall(function() S:HandleButton(tab) end) end

        if not tab.__activeAccent then
          tab.__activeAccent = tab:CreateTexture(nil, "OVERLAY")
          tab.__activeAccent:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 2, 1)
          tab.__activeAccent:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -2, 1)
          tab.__activeAccent:SetHeight(2)
          tab.__activeAccent:SetColorTexture(1.0, 0.82, 0.0, 0.9)
          tab.__activeAccent:Hide()
        end

        tab.__setSelectedOverride = function(t, selected)
          t:Enable()  -- belt and braces: the selected tab must stay clickable
          local fs = t.GetFontString and t:GetFontString()
          if fs then
            -- Redundant against the current widget, which already centres its
            -- label, but kept because S:HandleTab's effect on the font string
            -- cannot be verified here.
            fs:ClearAllPoints()
            fs:SetPoint("CENTER", t, "CENTER", 0, 0)
            fs:SetTextColor(selected and 1.00 or 0.95, selected and 0.88 or 0.80, selected and 0.28 or 0.20)
          end
          if t.__activeBg then t.__activeBg:Hide() end
          if t.__activeAccent then t.__activeAccent:SetShown(selected) end
        end
      end
    end

    -- Repaint the current selection now that overrides are installed, so the
    -- active tab is correct even outside the OnMailShow re-select path.
    local active = ns.MailboxUI and ns.MailboxUI._state and ns.MailboxUI._state.activeTab
    if active then
      for _, tab in pairs(frame.TabButtons) do
        if ns.Theme and ns.Theme.SetTabSelected then
          ns.Theme.SetTabSelected(tab, tab.tabId == active)
        end
      end
    end
  end

  AddShadow(frame)

  Skin.Refresh(frame)
end

-- ------------------------------------------------------------------
-- Claim (deferred, and second in line to EllesmereUI)
-- ------------------------------------------------------------------
-- Precedence used to be decided by timing alone: this file claimed ns.Skin at
-- file load and Core/Skin_EllesmereUI.lua replaced it at PLAYER_LOGIN. The two
-- use different idempotency keys, so nothing stopped both from running over the
-- same window if anything was built in between -- an ElvUI backdrop and shadow
-- under an EllesmereUI shell, and two selection overrides racing on each tab.
--
-- Now it is structural: with EllesmereUI loaded this skin stands down. It does
-- not test ns.SkinEllesmere, because that is published from the other file's
-- own PLAYER_LOGIN handler and handler order is not something to rely on; it
-- tests the host global, which is settled either way. The one case worth
-- recovering from is EllesmereUI being present but never claiming ns.Skin at
-- all -- so re-check once its own five-second handshake watchdog has had its
-- turn, and take the window then rather than leaving it unskinned.
--
-- The mirror of this -- EllesmereUI published AFTER login, by a load-on-demand
-- addon or a sub-addon that owns the global, so this skin claimed and possibly
-- painted first -- is handled on the other side: Activate() reads
-- ns.SkinAppliedBy and stands down rather than layering a shell over an
-- already-stripped window. Neither direction can now produce a half-skinned one.
local function Claim()
  if ns.Skin and ns.Skin ~= Skin then return end
  ns.Skin = Skin
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
  self:UnregisterEvent("PLAYER_LOGIN")
  if _G.EllesmereUI then
    if C_Timer and C_Timer.After then
      C_Timer.After(6, function() if not ns.Skin then Claim() end end)
    end
    return
  end
  Claim()
end)
