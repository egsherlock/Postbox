-- Postbox foundation :: bag-slot marking and mail-attachability policy.
--
-- Core/SendTab.lua greys out every bag slot holding something that cannot be
-- mailed while the Send tab is active, so the user sees at a glance what is
-- attachable.
--
-- Publishes: ns.Core.InventoryLock.MarkButton / .UnmarkButton / .ShouldLockForMail

local _, ns = ...

ns.Core = ns.Core or {}
local Core = ns.Core
Core.InventoryLock = Core.InventoryLock or {}

local M = Core.InventoryLock

-------------------------------------------------------------
-- Slot marking
-------------------------------------------------------------

-- White-on-transparent padlock glyph: desaturated first, then tinted, so the
-- red reads evenly.
local LOCK_TEXTURE = "Interface\\PetBattles\\PetBattle-LockIcon"
local LOCK_SIZE = 14
local LOCK_TINT = { 0.85, 0.40, 0.40 }
-- The grey: black this opaque over the icon leaves it at 45% of its light,
-- which is exactly what tinting the icon to 0.45 used to draw.
local SHADE_ALPHA = 0.55

-- Bag button implementations expose the item icon under either spelling.
local function IconOf(button)
  return button.icon or button.Icon
end

-- The grey is a layer of Postbox's own over the icon; the icon's colour is
-- left alone, because it is the bag's. The client sets it back to white each
-- time it draws an item's cooldown (ContainerFrameItemButtonMixin:
-- UpdateCooldown, in every redraw of a bag and on every BAG_UPDATE_COOLDOWN),
-- Baganator does the same for any item with a use (BGRUpdateCooldown), and
-- EllesmereUI on every render -- none of them followed by Postbox's hook. A
-- grey written into that colour was grey or white by whichever side painted
-- last, and every bag pass of Postbox's, one after each attach, turned the
-- items the bag had whitened darker until its next cooldown redraw turned
-- them back.
--
-- Drawn on the icon's own layer, one step above it, so the quality border,
-- the count and the other overlays stay as bright as they were under the
-- tint. The layer is read again at each mark, for a skin that moves the icon.
local function ShadeFor(button, icon)
  local layer, sublevel = "BORDER", 0
  if type(icon.GetDrawLayer) == "function" then
    local l, s = icon:GetDrawLayer()
    if type(l) == "string" then layer, sublevel = l, tonumber(s) or 0 end
  end
  sublevel = math.min(sublevel + 1, 7)

  local shade = button.pbLockShade
  if not shade then
    if type(button.CreateTexture) ~= "function" then return nil end
    shade = button:CreateTexture(nil, layer, nil, sublevel)
    shade:SetColorTexture(0, 0, 0, SHADE_ALPHA)
    shade:SetAllPoints(icon)
    -- A masked icon keeps its shape under the grey.
    if type(icon.GetNumMaskTextures) == "function" and type(icon.GetMaskTexture) == "function" then
      pcall(function()
        for i = 1, icon:GetNumMaskTextures() do
          local mask = icon:GetMaskTexture(i)
          if mask then shade:AddMaskTexture(mask) end
        end
      end)
    end
    shade.pbLayer, shade.pbSublevel = layer, sublevel
    button.pbLockShade = shade
  elseif shade.pbLayer ~= layer or shade.pbSublevel ~= sublevel then
    shade:SetDrawLayer(layer, sublevel)
    shade.pbLayer, shade.pbSublevel = layer, sublevel
  end
  return shade
end

-- Whether the bag already dims this item, with the client's context overlay
-- (80% black). Baganator's context fading does, while the attach flag is up,
-- for every item its mail test refuses -- bound and not allowed in the
-- warband bank, which is Postbox's own verdict on a bound item -- and the
-- grey laid under it took those items near black. There the padlock is
-- Postbox's whole mark. The field is written only by the button's
-- UpdateItemContextMatching, which the hook in SendTab.lua (17) follows, and
-- a search never touches it, so a mark always reads it current.
local function DimmedByBag(button)
  local results = ItemButtonUtil and ItemButtonUtil.ItemContextMatchResult
  local mismatch = type(results) == "table" and results.Mismatch or nil
  if mismatch == nil or button.itemContextMatchResult ~= mismatch then return false end
  local overlay = button.ItemContextOverlay
  return type(overlay) == "table" and type(overlay.IsShown) == "function" and overlay:IsShown() and true or false
end

-- Greys the slot's icon and shows a padlock over it. Marking a marked slot
-- again changes nothing on screen, whatever the bag has painted meanwhile.
--
-- The grey and the padlock are created at most once per button and reused
-- for the rest of the session. Bag buttons are updated constantly; creating
-- a texture per update would leak one texture per update for the life of the
-- session. Both are put back to full alpha at each mark: EllesmereUI's skin
-- fades every texture of a skinned button it did not mean to keep whenever it
-- restrips its windows, and ours were never among the ones it keeps.
function M.MarkButton(button)
  if not button then return end

  local icon = IconOf(button)
  local shade = icon and ShadeFor(button, icon)
  if shade then
    shade:SetAlpha(1)
    shade:SetShown(not DimmedByBag(button))
  end

  local overlay = button.pbLockOverlay
  if not overlay then
    if type(button.CreateTexture) ~= "function" then return end
    -- OVERLAY at a high sublevel: the glyph must sit above the item icon, the
    -- quality border and the stack-count string.
    overlay = button:CreateTexture(nil, "OVERLAY", nil, 7)
    overlay:SetSize(LOCK_SIZE, LOCK_SIZE)
    overlay:SetPoint("CENTER")
    overlay:SetTexture(LOCK_TEXTURE)
    overlay:SetDesaturated(true)
    overlay:SetVertexColor(LOCK_TINT[1], LOCK_TINT[2], LOCK_TINT[3])
    button.pbLockOverlay = overlay
  end

  overlay:SetAlpha(1)
  overlay:Show()
end

-- Hides (never destroys) the grey and the padlock. The icon itself was never
-- touched, so there is nothing of the bag's to put back.
function M.UnmarkButton(button)
  if not button then return end
  if button.pbLockShade then button.pbLockShade:Hide() end
  if button.pbLockOverlay then button.pbLockOverlay:Hide() end
end

-- Greys the slot's icon the way the client greys an attached one: an item
-- waiting in the attachment queue is spoken for, and the bags should say
-- so in the same voice. Desaturation only, no padlock -- it CAN be mailed,
-- it is about to be.
function M.MarkQueued(button)
  if not button then return end
  local icon = IconOf(button)
  if icon and icon.SetDesaturated then
    icon:SetDesaturated(true)
    button.pbQueuedGrey = true
  end
end

-- Is the item in this slot locked -- held by the client for a pending
-- action, which at a mailbox means attached to the mail being written?
function M.IsLockedAt(bag, slot)
  if type(bag) ~= "number" or type(slot) ~= "number" then return false end
  if not (C_Container and type(C_Container.GetContainerItemInfo) == "function") then return false end
  local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
  return ok and type(info) == "table" and info.isLocked == true
end

-- Puts the colour back, unless the client has meanwhile greyed the item
-- itself: an item that went from the queue into a slot is locked, and the
-- client's own grey for that must stand.
function M.UnmarkQueued(button)
  if not button or not button.pbQueuedGrey then return end
  button.pbQueuedGrey = nil
  local icon = IconOf(button)
  if not (icon and icon.SetDesaturated) then return end
  local bag
  if type(button.GetBagID) == "function" then
    local ok, id = pcall(button.GetBagID, button)
    if ok and type(id) == "number" then bag = id end
  end
  if bag == nil and type(button.GetParent) == "function" then
    local parent = button:GetParent()
    bag = (parent and type(parent.GetID) == "function") and parent:GetID() or nil
  end
  local slot = type(button.GetID) == "function" and button:GetID() or nil
  if not M.IsLockedAt(bag, slot) then icon:SetDesaturated(false) end
end

-------------------------------------------------------------
-- Mail policy
-------------------------------------------------------------

-- Bindings that still allow mailing to your own characters. Built from the
-- enum by name so a client that lacks a member simply omits it.
local ACCOUNT_BINDINGS = {}
do
  local bind = Enum and Enum.ItemBind
  if bind then
    local names = {
      "ToWoWAccount",
      "ToBnetAccount",
      "ToBnetAccountUntilEquipped",
      "ToAccount",
      "ToAccountUntilEquipped",
    }
    for i = 1, #names do
      local value = bind[names[i]]
      if type(value) == "number" then ACCOUNT_BINDINGS[value] = true end
    end
  end
end

local BINDING_LINE_TYPE = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.ItemBinding

-- ItemLocation.CreateFromBagAndSlot allocates a table per call, and this path
-- runs for every visible bag slot on every container update. Keep one instance
-- and re-point it.
local sharedLocation

local function LocationFor(bag, slot)
  if type(ItemLocation) ~= "table" then return nil end

  if sharedLocation and type(sharedLocation.SetBagAndSlot) == "function" then
    local ok = pcall(sharedLocation.SetBagAndSlot, sharedLocation, bag, slot)
    if ok then return sharedLocation end
    sharedLocation = nil
  end

  if type(ItemLocation.CreateFromBagAndSlot) ~= "function" then return nil end
  -- A method on ItemLocation: it needs ItemLocation as its first argument.
  local ok, location = pcall(ItemLocation.CreateFromBagAndSlot, ItemLocation, bag, slot)
  if not ok or type(location) ~= "table" then return nil end

  if type(location.SetBagAndSlot) == "function" then sharedLocation = location end
  return location
end

local function IsValidLocation(location)
  if not location or type(location.IsValid) ~= "function" then return false end
  local ok, valid = pcall(location.IsValid, location)
  return ok and valid and true or false
end

-- Verdicts are memoised on the item's GUID, which identifies the item instance
-- rather than the slot, so moving an item between bags reuses the answer. The
-- cache is dropped wholesale on BAG_UPDATE_DELAYED, which is what corrects a
-- transient "locked" verdict for an item still loading from the server.
local verdictCache = {}

do
  local watcher = CreateFrame("Frame")
  watcher:RegisterEvent("BAG_UPDATE_DELAYED")
  watcher:SetScript("OnEvent", function()
    -- Emptied in place: this fires on every loot all session, and a new
    -- table each time was garbage for nothing.
    for guid in pairs(verdictCache) do verdictCache[guid] = nil end
  end)
end

local function GuidFor(location)
  if not C_Item or type(C_Item.GetItemGUID) ~= "function" then return nil end
  if not IsValidLocation(location) then return nil end
  local ok, guid = pcall(C_Item.GetItemGUID, location)
  if ok and type(guid) == "string" and guid ~= "" then return guid end
  return nil
end

-- nil = "this line says nothing decisive", true = soulbound, false = mailable.
local function ClassifyBindingLine(line)
  local bonding = tonumber(line.bonding)
  if bonding and ACCOUNT_BINDINGS[bonding] then return false end

  local text = line.leftText
  if type(text) ~= "string" then return nil end

  if ITEM_ACCOUNTBOUND and text == ITEM_ACCOUNTBOUND then return false end
  if ITEM_BNETACCOUNTBOUND and text == ITEM_BNETACCOUNTBOUND then return false end
  if ITEM_BIND_TO_ACCOUNT and text == ITEM_BIND_TO_ACCOUNT then return false end
  if ITEM_SOULBOUND and text == ITEM_SOULBOUND then return true end

  return nil
end

-- Consulted only when the cheaper checks were inconclusive. SurfaceArgs has to
-- be called on the tooltip data and again on each line before the line's text
-- fields are readable; that sequence is dictated by the API.
local function TooltipVerdict(bag, slot)
  if not C_TooltipInfo or type(C_TooltipInfo.GetBagItem) ~= "function" then return nil end

  local ok, data = pcall(C_TooltipInfo.GetBagItem, bag, slot)
  if not ok or type(data) ~= "table" then return nil end

  local surface = TooltipUtil and TooltipUtil.SurfaceArgs
  if surface then pcall(surface, data) end

  local lines = data.lines
  if type(lines) ~= "table" then return nil end

  for i = 1, #lines do
    local line = lines[i]
    if type(line) == "table" then
      if surface then pcall(surface, line) end
      -- With a line type available we stop at the binding line instead of
      -- scanning the whole tooltip.
      if (not BINDING_LINE_TYPE) or line.type == BINDING_LINE_TYPE then
        local verdict = ClassifyBindingLine(line)
        if verdict ~= nil then return verdict end
      end
    end
  end

  return nil
end

local function Resolve(bag, slot, location, info)
  -- Warbound until equipped: the container reports it as bound, but it can
  -- still be mailed to your own characters.
  if C_Item and type(C_Item.IsBoundToAccountUntilEquip) == "function" and IsValidLocation(location) then
    local ok, warbound = pcall(C_Item.IsBoundToAccountUntilEquip, location)
    if ok and warbound then return false end
  end

  -- The item's declared bind type settles most account-wide bindings without
  -- touching a tooltip at all.
  local link = info.hyperlink
  local getItemInfo = C_Item and C_Item.GetItemInfo or _G.GetItemInfo
  if link and type(getItemInfo) == "function" then
    -- bindType is GetItemInfo's 14th return; nil for an item not yet cached.
    local ok, _, _, _, _, _, _, _, _, _, _, _, _, _, bindType = pcall(getItemInfo, link)
    if ok and bindType ~= nil and ACCOUNT_BINDINGS[bindType] then return false end
  end

  local verdict = TooltipVerdict(bag, slot)
  if verdict ~= nil then return verdict end

  -- Bound, but the kind could not be determined. Greying a mailable item is
  -- the harmless failure; letting the user believe an unmailable one can be
  -- attached is not.
  return true
end

-- True only when the item in this slot definitely cannot be mailed.
function M.ShouldLockForMail(bag, slot)
  if type(bag) ~= "number" or type(slot) ~= "number" then return false end
  if not C_Container or type(C_Container.GetContainerItemInfo) ~= "function" then return false end

  local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
  if not ok or type(info) ~= "table" then return false end  -- empty slot
  if not info.isBound then return false end                 -- not bound at all

  local location = LocationFor(bag, slot)
  local guid = GuidFor(location)
  if guid then
    local cached = verdictCache[guid]
    if cached ~= nil then return cached end
  end

  local verdict = Resolve(bag, slot, location, info)
  if guid then verdictCache[guid] = verdict end
  return verdict
end
