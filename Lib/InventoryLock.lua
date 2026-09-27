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
local ICON_GREY = 0.45

-- Bag button implementations expose the item icon under either spelling.
local function IconOf(button)
  return button.icon or button.Icon
end

-- Greys the slot's icon and shows a padlock over it.
--
-- The overlay is created at most once per button and reused for the rest of
-- the session. Bag buttons are updated constantly; creating a texture per
-- update would leak one texture per update for the life of the session.
--
-- The icon's tint is captured before greying and put back EXACTLY on unmark:
-- the button belongs to the client (or to a bag addon), and another consumer
-- may have tinted the icon for its own reasons -- restoring to hard white
-- would erase their state, not ours.
function M.MarkButton(button)
  if not button then return end

  local icon = IconOf(button)
  if icon and icon.SetVertexColor then
    if not button.pbLockSavedTint and icon.GetVertexColor then
      local r, g, b, a = icon:GetVertexColor()
      -- Re-marking an already-grey icon must not capture our own grey.
      if r ~= ICON_GREY or g ~= ICON_GREY or b ~= ICON_GREY then
        button.pbLockSavedTint = { r or 1, g or 1, b or 1, a or 1 }
      end
    end
    icon:SetVertexColor(ICON_GREY, ICON_GREY, ICON_GREY)
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

  overlay:Show()
end

-- Restores the icon and hides (never destroys) the overlay.
function M.UnmarkButton(button)
  if not button then return end

  local icon = IconOf(button)
  if icon and icon.SetVertexColor then
    local saved = button.pbLockSavedTint
    if saved then
      icon:SetVertexColor(saved[1], saved[2], saved[3], saved[4])
    else
      icon:SetVertexColor(1, 1, 1)
    end
    button.pbLockSavedTint = nil
  end

  if button.pbLockOverlay then
    button.pbLockOverlay:Hide()
  end
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
-- rather than the slot: a split stack or a new item is a new GUID and is
-- judged afresh, and an item nothing has happened to is not judged twice.
--
-- The memo used to be dropped wholesale on every BAG_UPDATE_DELAYED, which
-- fires on every loot, so a visit that collected anything between two trips
-- to the Send tab read every bound item's tooltip again on the second -- the
-- costly part of a verdict. Now a bag's verdicts go when THAT bag changes
-- (BAG_UPDATE names it). Whatever can change a verdict updates the bags it
-- touches: a move, a split, an item added or taken, an item equipped from a
-- bag (which is how a warbound-until-equipped item becomes soulbound) and put
-- back. A bag nothing happened to keeps its verdicts.
--
-- A "locked" reached only because nothing decisive could be read yet -- an
-- item still loading from the server -- is provisional, and still goes on
-- BAG_UPDATE_DELAYED as every verdict used to: that is what corrects it once
-- the data has arrived.
local verdictCache = {}   -- guid -> verdict
local provisional = {}    -- guid -> true: a verdict nothing decisive backed
local judgedIn = {}       -- bag -> { guid = true }, the verdicts judged there

do
  local watcher = CreateFrame("Frame")
  watcher:RegisterEvent("BAG_UPDATE")
  watcher:RegisterEvent("BAG_UPDATE_DELAYED")
  watcher:SetScript("OnEvent", function(_, event, bag)
    if event == "BAG_UPDATE" then
      local guids = judgedIn[bag]
      if not guids then return end
      judgedIn[bag] = nil
      for guid in pairs(guids) do
        verdictCache[guid] = nil
        provisional[guid] = nil
      end
      return
    end
    -- Emptied in place: this fires on every loot all session, and a new
    -- table each time was garbage for nothing.
    for guid in pairs(provisional) do
      verdictCache[guid] = nil
      provisional[guid] = nil
    end
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

-- How many tooltips the verdicts have read this session: the costly part of a
-- verdict, counted for /postbox debug (Postbox.lua, 5b).
M.tooltipScans = 0

-- Consulted only when the cheaper checks were inconclusive. SurfaceArgs has to
-- be called on the tooltip data and again on each line before the line's text
-- fields are readable; that sequence is dictated by the API.
local function TooltipVerdict(bag, slot)
  if not C_TooltipInfo or type(C_TooltipInfo.GetBagItem) ~= "function" then return nil end

  M.tooltipScans = M.tooltipScans + 1
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

-- -> the verdict, and whether anything decisive was read to reach it.
local function Resolve(bag, slot, location, info)
  -- Warbound until equipped: the container reports it as bound, but it can
  -- still be mailed to your own characters.
  if C_Item and type(C_Item.IsBoundToAccountUntilEquip) == "function" and IsValidLocation(location) then
    local ok, warbound = pcall(C_Item.IsBoundToAccountUntilEquip, location)
    if ok and warbound then return false, true end
  end

  -- The item's declared bind type settles most account-wide bindings without
  -- touching a tooltip at all.
  local link = info.hyperlink
  local getItemInfo = C_Item and C_Item.GetItemInfo or _G.GetItemInfo
  if link and type(getItemInfo) == "function" then
    -- bindType is GetItemInfo's 14th return; nil for an item not yet cached.
    local ok, _, _, _, _, _, _, _, _, _, _, _, _, _, bindType = pcall(getItemInfo, link)
    if ok and bindType ~= nil and ACCOUNT_BINDINGS[bindType] then return false, true end
  end

  local verdict = TooltipVerdict(bag, slot)
  if verdict ~= nil then return verdict, true end

  -- Bound, but the kind could not be determined. Greying a mailable item is
  -- the harmless failure; letting the user believe an unmailable one can be
  -- attached is not.
  return true, false
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

  local verdict, decided = Resolve(bag, slot, location, info)
  if guid then
    verdictCache[guid] = verdict
    if not decided then provisional[guid] = true end
    local guids = judgedIn[bag]
    if not guids then
      guids = {}
      judgedIn[bag] = guids
    end
    guids[guid] = true
  end
  return verdict
end
