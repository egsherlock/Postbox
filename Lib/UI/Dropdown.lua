-- Postbox foundation :: the select control.
--
-- A label, a toggle button, and a drop-down list of items, built entirely from
-- plain frames the addon owns. Blizzard's menu and dropdown APIs are avoided
-- deliberately (see COMBAT_TAINT.md), which is also what lets the list panel be
-- kept fully opaque.
--
-- Publishes: ns.Core.UI.Dropdown.Create / .CloseAll

local _, ns = ...

ns.Core = ns.Core or {}
local Core = ns.Core
Core.UI = Core.UI or {}
Core.UI.Dropdown = Core.UI.Dropdown or {}

local Dropdown = Core.UI.Dropdown

-- The addon's own white tile: the list panel's fill and edge must survive a
-- UI pack's loose-file texture overrides (see Lib/UI/Theme.lua).
local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"

local DEFAULT_HEIGHT = 30
local DEFAULT_ROW_HEIGHT = 20
local DEFAULT_TOGGLE_WIDTH = 200
local DEFAULT_TOGGLE_HEIGHT = 22
local LIST_PADDING = 4
local LIST_GAP = 2
-- Twelve rows of the default height plus padding. A list taller than this
-- scrolls instead of growing (opts.maxListHeight overrides).
local DEFAULT_MAX_LIST_HEIGHT = 248
local SCROLLBAR_INSET = 3
-- Clear of every sibling widget's border overlay in the owning window.
local LIST_LEVEL_OFFSET = 40

-- Every list this module has built. Weak-keyed so a discarded dropdown does not
-- pin its frames for the rest of the session.
local lists = setmetatable({}, { __mode = "k" })

-- Full-screen click catcher. Without it a list only closes when its own toggle
-- is clicked again or another list opens; clicking anywhere else leaves it
-- hanging over the UI.
local catcher

local function AnyListShown()
  for list in pairs(lists) do
    if list:IsShown() then return true end
  end
  return false
end

local function UpdateCatcher()
  if catcher and not AnyListShown() then catcher:Hide() end
end

local function ShowCatcher(level)
  if not catcher then
    catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:EnableMouse(true)
    catcher:Hide()
    catcher:SetScript("OnMouseDown", function() Dropdown.CloseAll() end)
  end

  catcher:SetFrameLevel(level)
  catcher:Show()
end

-- Closes every list this module created, except the one passed in. Called with
-- no argument by Core/SendTab.lua and Core/RecipientManager.lua before they
-- open their own popups, so two lists can never overlap.
function Dropdown.CloseAll(except)
  for list in pairs(lists) do
    if list ~= except and list:IsShown() then list:Hide() end
  end
  UpdateCatcher()
end

function Dropdown.Create(parent, opts)
  opts = type(opts) == "table" and opts or {}

  local Theme = Core.UI.Theme
  local items = type(opts.items) == "table" and opts.items or {}
  local rowHeight = tonumber(opts.rowHeight) or DEFAULT_ROW_HEIGHT
  local toggleWidth = tonumber(opts.toggleWidth) or DEFAULT_TOGGLE_WIDTH

  local container = CreateFrame("Frame", nil, parent)
  container:SetHeight(tonumber(opts.height) or DEFAULT_HEIGHT)

  -- Ids are mixed-type — Core/OptionsPanel.lua uses the string "auto" alongside
  -- integers — so identity comparison must never assume a type.
  if opts.defaultId ~= nil then
    container._selectedId = opts.defaultId
  elseif items[1] then
    container._selectedId = items[1].id
  end

  if opts.label then
    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", container, "LEFT", 0, 0)
    label:SetText(opts.label)
    if Theme and Theme.BindFont then Theme.BindFont(label, "small") end
    container._label = label
  end

  -- Through the theme's button factory, so the select control is built from the
  -- same template as every other push button in the addon. It used to be the
  -- one UIPanelButtonTemplate here, which on a stock UI put a classic
  -- gold-bracket button beside the modern ones in the options panel and 2px
  -- from a flat plate tile in the recipient manager's sort group.
  local toggle
  if Theme and type(Theme.CreateButton) == "function" then
    toggle = Theme.CreateButton(opts.toggleName, container)
  else
    toggle = CreateFrame("Button", opts.toggleName, container, "UIPanelButtonTemplate")
  end
  toggle:SetSize(toggleWidth, tonumber(opts.toggleHeight) or DEFAULT_TOGGLE_HEIGHT)

  -- alignRight pins the toggle to the container's right edge instead of
  -- trailing the label. Without it a column of dropdowns is ragged, each toggle
  -- starting wherever its own label happens to end.
  if opts.alignRight then
    toggle:SetPoint("RIGHT", container, "RIGHT", 0, 0)
  elseif container._label then
    toggle:SetPoint("LEFT", container._label, "RIGHT", 6, 0)
  else
    toggle:SetPoint("LEFT", container, "LEFT", 0, 0)
  end

  -- Tagged so a host-UI skin treats it like the addon's other push buttons.
  toggle.__postboxButton = true
  container._toggle = toggle

  local function NameFor(id)
    for i = 1, #items do
      if items[i].id == id then return items[i].name end
    end
    -- Unknown default: show the first item rather than an empty toggle. The
    -- selection itself is left as given.
    return (items[1] and items[1].name) or ""
  end

  toggle:SetText(NameFor(container._selectedId))

  local list  -- built on first open

  local function BuildList()
    if list then return list end

    local colors = (Theme and Theme.MenuColors) or nil
    local hover = colors and colors.hover or { 0.90, 0.78, 0.30, 0.18 }

    local contentHeight = #items * rowHeight
    local maxHeight = tonumber(opts.maxListHeight) or DEFAULT_MAX_LIST_HEIGHT
    local scrolling = (LIST_PADDING * 2) + contentHeight > maxHeight
    local viewport = maxHeight - (LIST_PADDING * 2)

    list = CreateFrame("Frame", nil, toggle, "BackdropTemplate")
    list:SetPoint("TOPRIGHT", toggle, "BOTTOMRIGHT", 0, -LIST_GAP)
    list:SetWidth(tonumber(opts.listWidth) or toggleWidth)
    list:SetHeight(scrolling and maxHeight or ((LIST_PADDING * 2) + contentHeight))
    list:SetFrameStrata("FULLSCREEN_DIALOG")

    -- The list is a popup, and the addon has one popup surface: the same card
    -- the contact picker and the type-ahead list wear. Going through the
    -- addon's surface entry point rather than hand-rolling a backdrop is what
    -- gets it the shared fill, border and stone grain on a stock UI *and* the
    -- `__postboxPanel` tag both host-UI skins walk for -- without which this is
    -- the one Postbox-coloured panel left inside an otherwise host-styled
    -- window. Resolved at first open, not at load: this file is foundation and
    -- loads before the addon theme.
    --
    -- __pbPopupAlways: the strata heuristic behind the popup opacity floor
    -- cannot see that this is a popup when the OWNING window already sits at
    -- FULLSCREEN_DIALOG (the options panel), which left this one list as
    -- see-through as the window. Declare it instead of hoping.
    list.__pbPopupAlways = true
    local surface = ns.Theme and ns.Theme.ApplyCard
    if type(surface) == "function" then
      surface(list)
    else
      -- No addon theme (foundation used on its own): a solid white 8x8 tinted
      -- by the menu palette, with a 1px edge.
      local fill = colors and colors.fill or { 0.05, 0.05, 0.06, 1 }
      local border = colors and colors.border or { 0.46, 0.36, 0.24, 0.55 }
      list:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
      list:SetBackdropColor(fill[1], fill[2], fill[3], fill[4])
      list:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
      list.__postboxPanel = "card"
    end
    list:Hide()

    -- Long lists scroll inside a fixed height rather than running off the
    -- screen: rows go on a scroll child, and a hairline track with a light
    -- draggable thumb carries the position. Deliberately minimal -- no
    -- buttons, no Blizzard scroll templates.
    local rowParent = list
    if scrolling then
      local scroll = CreateFrame("ScrollFrame", nil, list)
      scroll:SetPoint("TOPLEFT", list, "TOPLEFT", LIST_PADDING, -LIST_PADDING)
      scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT",
        -(LIST_PADDING + SCROLLBAR_INSET + 4), LIST_PADDING)

      local content = CreateFrame("Frame", nil, scroll)
      content:SetSize(1, contentHeight)
      scroll:SetScrollChild(content)
      scroll:SetScript("OnSizeChanged", function(_, width)
        content:SetWidth(width or 1)
      end)

      -- The track rides a child frame, not the list itself: the list is a
      -- tagged panel, and a host skin's repaint fades every texture region
      -- the panel owns directly (the thumb survives for exactly this reason
      -- -- its art lives on the thumb frame).
      local trackHolder = CreateFrame("Frame", nil, list)
      trackHolder:SetWidth(3)
      trackHolder:SetPoint("TOPRIGHT", list, "TOPRIGHT", -SCROLLBAR_INSET, -LIST_PADDING)
      trackHolder:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -SCROLLBAR_INSET, LIST_PADDING)
      local track = trackHolder:CreateTexture(nil, "ARTWORK")
      track:SetAllPoints()
      track:SetColorTexture(1, 1, 1, 0.08)

      local span = contentHeight - viewport
      local thumbHeight = math.max(20, viewport * viewport / contentHeight)
      local thumb = CreateFrame("Frame", nil, list)
      thumb:SetSize(3, thumbHeight)
      thumb:EnableMouse(true)
      local thumbArt = thumb:CreateTexture(nil, "OVERLAY")
      thumbArt:SetAllPoints()
      thumbArt:SetColorTexture(1, 1, 1, 0.35)

      local function SetOffset(offset)
        offset = math.max(0, math.min(span, offset))
        scroll:SetVerticalScroll(offset)
        local travel = viewport - thumbHeight
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", list, "TOPRIGHT", -SCROLLBAR_INSET,
          -LIST_PADDING - (span > 0 and (offset / span) * travel or 0))
      end
      SetOffset(0)
      list._setOffset = SetOffset
      list._viewport = viewport
      list._scroll = scroll
      list._content = content

      local function OnWheel(_, delta)
        SetOffset(scroll:GetVerticalScroll() - delta * rowHeight * 3)
      end
      list:EnableMouseWheel(true)
      list:SetScript("OnMouseWheel", OnWheel)
      scroll:EnableMouseWheel(true)
      scroll:SetScript("OnMouseWheel", OnWheel)

      thumb:SetScript("OnMouseDown", function(self)
        local scale = self:GetEffectiveScale()
        local _, startY = GetCursorPosition()
        local startOffset = scroll:GetVerticalScroll()
        local travel = viewport - thumbHeight
        self:SetScript("OnUpdate", function()
          if travel <= 0 then return end
          local _, cursorY = GetCursorPosition()
          SetOffset(startOffset + ((startY - cursorY) / scale) * (span / travel))
        end)
      end)
      thumb:SetScript("OnMouseUp", function(self)
        self:SetScript("OnUpdate", nil)
      end)

      rowParent = content
    end

    list._rows = {}
    for i = 1, #items do
      local item = items[i]

      local row = CreateFrame("Button", nil, rowParent)
      row:SetHeight(rowHeight)
      row._itemId = item.id
      list._rows[#list._rows + 1] = row
      if scrolling then
        row:SetPoint("TOPLEFT", rowParent, "TOPLEFT", 0, -((i - 1) * rowHeight))
        row:SetPoint("RIGHT", rowParent, "RIGHT", 0, 0)
      else
        row:SetPoint("TOPLEFT", rowParent, "TOPLEFT", LIST_PADDING, -LIST_PADDING - ((i - 1) * rowHeight))
        row:SetPoint("RIGHT", rowParent, "RIGHT", -LIST_PADDING, 0)
      end

      local bg = row:CreateTexture(nil, "BACKGROUND")
      bg:SetAllPoints()
      bg:SetColorTexture(0, 0, 0, 0)

      -- An item may carry its own art: { texture= or atlas=, aspect= }.
      -- Drawn at row height beside the caption, so a list of visual choices
      -- shows the choices.
      local textOffset = LIST_PADDING
      if type(item.icon) == "table" then
        local art = row:CreateTexture(nil, "ARTWORK")
        local size = rowHeight - 4
        art:SetSize(size, size * (item.icon.aspect or 1))
        art:SetPoint("LEFT", row, "LEFT", LIST_PADDING, 0)
        if item.icon.atlas then
          art:SetAtlas(item.icon.atlas)
        else
          art:SetTexture(item.icon.texture)
        end
        textOffset = LIST_PADDING + size + 6
      end

      local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      text:SetPoint("LEFT", row, "LEFT", textOffset, 0)
      text:SetText(item.name)
      if Theme and Theme.BindFont then Theme.BindFont(text, "small") end

      -- The current selection's marker: a 2px accent bar on the row's left
      -- edge, painted on open. Feedback that a choice is in effect even when
      -- the toggle's caption does not repeat it (an owner may keep a fixed
      -- title there instead).
      local mark = row:CreateTexture(nil, "ARTWORK")
      mark:SetWidth(2)
      mark:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
      mark:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 1)
      mark:Hide()
      row._selMark = mark

      row:SetScript("OnEnter", function()
        bg:SetColorTexture(hover[1], hover[2], hover[3], hover[4])
      end)
      row:SetScript("OnLeave", function()
        bg:SetColorTexture(0, 0, 0, 0)
      end)
      row:SetScript("OnClick", function()
        container._selectedId = item.id
        toggle:SetText(item.name)
        list:Hide()
        if container._onChange then container._onChange(item.id, item.name) end
      end)
    end

    list:SetScript("OnHide", UpdateCatcher)
    lists[list] = true
    return list
  end

  local function CloseList()
    if list and list:IsShown() then list:Hide() end
    -- Unconditional: hiding the owning window fires OnHide on its children too,
    -- and the order of those is not guaranteed.
    UpdateCatcher()
  end

  local function OpenList()
    local built = not list
    BuildList()
    Dropdown.CloseAll(list)

    -- The list is built lazily on first open, so it misses the skin pass the
    -- owning window had. Hand it over now -- from the container, because both
    -- skins walk a frame's CHILDREN, and the list is a child of the toggle.
    if built and ns.Skin and ns.Skin.Refresh then
      pcall(ns.Skin.Refresh, container)
    end

    local owner = container:GetParent()
    local base = (owner and owner:GetFrameLevel()) or 0
    local level = base + LIST_LEVEL_OFFSET

    list:SetFrameLevel(level)
    ShowCatcher(level - 1)
    list:Show()
    list:Raise()

    -- Paint the selection markers for THIS open: selection may have changed
    -- since the last one, and the accent is resolved live (a host UI's own
    -- colour wins when the addon theme is present).
    if list._rows then
      local r, g, b = 0.90, 0.78, 0.30
      local themed = ns.Theme
      if themed and type(themed.GetAccent) == "function" then
        r, g, b = themed.GetAccent()
      end
      for i = 1, #list._rows do
        local row = list._rows[i]
        if row._selMark then
          if row._itemId == container._selectedId then
            row._selMark:SetColorTexture(r, g, b, 0.9)
            row._selMark:Show()
          else
            row._selMark:Hide()
          end
        end
      end
    end

    -- A scrolling list opens with the current selection in view rather than
    -- at the top of a long ride down. Width is re-asserted here because the
    -- scroll child's is derived, and the first OnSizeChanged can land before
    -- the list has real geometry.
    if list._setOffset then
      if list._content and list._scroll then
        list._content:SetWidth(list._scroll:GetWidth())
      end
      local index
      for i = 1, #items do
        if items[i].id == container._selectedId then index = i break end
      end
      if index then
        local rowHeightUsed = rowHeight
        list._setOffset(((index - 1) * rowHeightUsed) - (list._viewport - rowHeightUsed) / 2)
      end
    end
  end

  toggle:SetScript("OnClick", function()
    if list and list:IsShown() then
      CloseList()
    else
      OpenList()
    end
  end)

  -- An options panel closed with Escape would otherwise leave an orphaned list
  -- panel visible at fullscreen-dialog strata. Hiding a parent fires OnHide on
  -- its children, so this covers the whole owning window going away too.
  container:HookScript("OnHide", CloseList)

  function container:GetSelectedId()
    return container._selectedId
  end

  -- Sets the selection and the visible label together.
  function container:SetSelectedId(id)
    container._selectedId = id
    toggle:SetText(NameFor(id))
  end

  -- Sets the toggle's visible label only, without changing the selection: an
  -- external source of truth re-syncing itself into the widget.
  function container:SetText(text)
    toggle:SetText(text or "")
  end

  function container:SetChangeCallback(fn)
    container._onChange = fn
  end

  return container
end
