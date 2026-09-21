local _, ns = ...

-- Postbox :: the compose screen.
--
-- Address a mail (by typing with autocomplete, or by picking from categorised
-- contacts), give it a subject and a body, attach up to twelve items, attach
-- gold or mark it cash-on-delivery, see what the postage costs, and send it.
--
-- Three things in here are load-bearing and are the reason this file is
-- structured the way it is:
--
--   1. SendMail() is ASYNCHRONOUS. The draft is held until the server confirms,
--      because a mistyped recipient is the common failure and clearing on click
--      loses everything the user typed. Section 8.
--   2. The send frame's money state PERSISTS between mails. Both C.O.D. and
--      attached money are therefore set explicitly on every send, with the
--      unused one zeroed. ClearSendMail() is deliberately never called -- it
--      would detach the user's items. Section 3.
--   3. The To: box COMPLETES ITSELF as you type -- inline, from the same ranked
--      list the type-ahead popup is showing, with the auto-added tail selected
--      so the next keystroke replaces it. It completes only on an insertion at
--      the end of the text and it only ever EXTENDS what was typed, never
--      rewrites it. Section 15a, which is also where Tab-to-accept and
--      Tab-to-cycle live.
--
-- Everything drawn here sources its colour, font, metric and surface from
-- Core/Theme.lua. Nothing below introduces one of its own.

ns.SendTab = ns.SendTab or {}
local ST = ns.SendTab

-- Core/Theme.lua and Core/Locales.lua both precede this file in Postbox.toc and
-- neither is optional: without the design system there is nothing to draw with
-- and without the locale table there is nothing to write. Everything else --
-- the mail rules, the contact service, the recipient store, the window shell,
-- the optional host-UI skin -- is resolved at call time so a TOC reorder or a
-- missing skin degrades instead of erroring.
local Theme = ns.Theme
local L     = ns.L
local M     = Theme.Metrics

local function Helpers()  return ns.Helpers end
local function Contacts() return ns.ContactService end

local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max

-- Forward declaration. Section 15a owns the inline completion state that lives
-- on the panel; the two places that overwrite the To: box FROM CODE -- a name
-- picked out of a list, and a draft being blanked -- both sit above it and both
-- have to drop that state, or the next keystroke would be measured against text
-- the player never typed.
local ResetInlineCompletion

-- Section 18a, the attachment queue: reached from the slot refresh (5) and
-- the send outcome (8), both of which are defined before it.
local RefreshQueueLabel, TopUpFromQueue, ContinueQueue

-------------------------------------------------------------
-- 1. Geometry, and the invariant that holds the screen together
--
-- The compose screen is a vertical stack of FIXED bands with exactly ONE
-- elastic band -- the message body -- absorbing everything left over:
--
--   margin / recipient caption + field / category bar / subject caption + field
--   / message caption / [[ MESSAGE BODY ]] / attachments / money row /
--   guidance / Send button / margin
--
-- THE INVARIANT, and it lives here and nowhere else:
--
--   Every fixed band is named below and summed by PanelHeightFor(). This
--   screen's minimum height is DERIVED from that sum plus a message body of
--   MESSAGE_MIN_LINES lines -- ST.MinPanelHeight, which Core/MailboxUI.lua
--   takes as one of the two demands the window's resize floor is the taller of
--   (the other is the collect screen's list floor). Because the floor is
--   derived rather than chosen, the window cannot be made short enough for the
--   elastic band to reach zero, so the bands cannot collide.
--
--   ADDING A BAND MEANS ADDING IT TO PanelHeightFor(). That is the entire
--   maintenance rule, and it is the only thing standing between this screen and
--   the defect it was written to kill: a hardcoded 480x400 window floor that had
--   nothing to do with the content, at which the message box was a couple of
--   pixels tall with one row of attachments and INVERTED with two -- its caption
--   landing on top of the attachment band and the field itself gone.
--
-- Every height that depends on TEXT is measured from the client's own fonts
-- rather than guessed in pixels (LineHeight below), so a locale or a host UI
-- with a taller font moves the captions, the message minimum and the window
-- floor together instead of one of the three drifting.
-------------------------------------------------------------

-- Every band gap and band height below is a Theme.Metrics token or a stated
-- exception to one. Nothing here is a bare pixel count that happens to agree
-- with the design system: the panel margin is M.inset (the tab bar above and
-- the collect screen beside it use the same one), the caption-to-field gap is
-- M.labelGap, the field height is M.controlHeight and the bar is M.tileHeight.
--
-- BAND_GAP is the one that is NOT the ladder rung its old name claimed. It was
-- called SECTION_GAP while holding M.gap, which is the SIBLING step, not
-- M.sectionGap (14). It stays M.gap and is renamed to say so: this screen is
-- one continuous form from recipient to Send button rather than a set of
-- separable groups, and the two places it is used -- subject field to message
-- caption, message body to attachments -- are band boundaries in a stack whose
-- total height is what the window's floor is derived from. Widening them to
-- M.sectionGap would raise that floor by 12px to buy grouping this screen does
-- not have, so the value is deliberate and the name now matches it.
local BAND_GAP          = M.gap
-- The recipient field and the category bar under it are ONE control as far as
-- the eye is concerned, so the gap between them is the ladder's smallest rung
-- (M.space.hair), the same one that binds a caption to its field.
local BAR_GAP           = M.space.hair
-- The category bar (section 13) is a row of flat tiles in a dense strip: the
-- lightest control class the theme names, and exactly what M.tileHeight is for.
-- It is declared here with the other bands because the height sum below has to
-- see it, and Theme.CreatePlate("tile") gives every tile the same height from
-- the same token.
local BAR_H             = M.tileHeight
-- Caption to the field it names is M.labelGap everywhere; the SUBJECT caption
-- is the one that follows a control rather than a field, and the bar above it
-- is already inset, so it gets the padding rung instead of the section one.
local SUBJECT_LABEL_GAP = M.tightGap
local MONEY_INPUT_H     = M.controlHeight -- the money boxes and the C.O.D. box share it
-- The money row is its tallest control plus a hair of air, not a round number:
-- it was 28px around controls of 22, and those 6px were dead space directly
-- above the Send button -- exactly the space the message box was short of.
local MONEY_ROW_H       = MONEY_INPUT_H + M.tightGap  -- 28
-- Deliberately NOT M.buttonHeight (26). Send is this screen's one irreversible
-- action and the only full-width control on it; the theme's button height is
-- for the buttons that sit several to a row, and giving the primary action the
-- same weight as one of those is the hierarchy the ladder exists to express.
-- 28 is M.tabHeight -- "the heaviest control on screen" -- which is what this
-- is, and it is written out rather than borrowed from the tab token because a
-- change to the window tabs must not silently move the compose screen's floor.
local SEND_BUTTON_H     = 28
local GUIDANCE_GAP      = M.tightGap      -- 4

-- The guidance band above the Send button (section 7) is reserved permanently
-- rather than grown on demand: re-laying out the body while somebody is typing a
-- recipient is worse than the pixels. Two lines' worth, because the longest note
-- wraps to two at the minimum window width in the wordiest locale and a clipped
-- warning is the one thing worse than a shorter message box. MEASURED at two
-- lines rather than rounded up to 28.
local GUIDANCE_LINES = 2

-- The message box's hard floor, in lines of its own font. TWO, and two is a
-- GUARANTEE rather than a size anybody will normally see.
--
-- It was five, on the reasoning that the compose screen's demand IS the window's
-- minimum and that minimum ships as the default, so it had to be comfortable
-- rather than merely legal. That reasoning no longer holds: the collect screen
-- publishes a floor of its own now (Core/CollectTab.lua, CT.MinPanelHeight --
-- five compact mail rows or three standard ones), the window's minimum is the
-- TALLER of the two demands, and the two land within a few pixels of each other.
-- Whichever wins, the compose screen at the window's floor has as much height as
-- the collect screen needed, and the body -- this screen's one elastic band --
-- absorbs every pixel of the surplus. In practice the box shows well more than
-- two lines; two is the number below which the bands are not permitted to go.
--
-- Lowering it is what buys the collect screen its rows without the window's
-- minimum climbing to the sum of both screens' comfortable sizes. What it costs
-- is the second reason five was chosen: at exactly two lines the wrap is ~32px,
-- which is what the classic scroll bar's two end buttons alone want, so a bar
-- forced on screen at the absolute floor would be cramped. It takes both the
-- window at its floor AND the elastic growth exhausted (section 16b) for that to
-- happen, and the bar is hidden whenever there is nothing to scroll.
local MESSAGE_MIN_LINES = 2

-- What the message wrap gives up to its border, top and bottom. The single-line
-- fields use the same inset; the body used to use M.gap, which cost it 4px of
-- text for no visual gain.
local BODY_PAD = M.tightGap

-- Attachments. Read the client's own limit; twelve is only the fallback.
local SEND_SLOT_COUNT    = (type(ATTACHMENTS_MAX_SEND) == "number" and ATTACHMENTS_MAX_SEND) or 12
local SEND_SLOTS_PER_ROW = 6
local SLOT_SIZE          = M.slotSize            -- 36
local SLOT_STEP_X        = SLOT_SIZE + M.gap     -- 42
-- A second row of slots grows the WINDOW by its height rather than stealing
-- height from the message body, so Core/MailboxUI.lua has to grow the window by
-- exactly this much. It derives the same figure from the same two metrics; the
-- two must never be written as independent literals.
local ATTACH_ROW_STEP    = SLOT_SIZE + M.tightGap  -- 40

local MAX_SUGGESTIONS = 8

-- The rendered height of N lines of a text role, as the CLIENT lays them out --
-- not a pixel count chosen here. Three derived heights read this (the field
-- captions, the guidance band and the message box's floor) and all three would
-- be wrong on a client whose fonts differ.
--
-- Measured with the line breaks actually in place rather than by multiplying one
-- line's height, so whatever leading the renderer puts between lines is included
-- instead of being the reason a two-line warning clips.
--
-- One hidden font string does every measurement; each answer is cached.
local measureString
local measuredHeights = {}

local function TextHeight(role, lines)
  lines = max(1, floor(tonumber(lines) or 1))

  local key = role .. ":" .. lines
  local cached = measuredHeights[key]
  if cached then return cached end

  local font = Theme.FontObject(role)
  local height

  if not measureString and UIParent then
    measureString = UIParent:CreateFontString(nil, "BACKGROUND")
    if measureString then measureString:Hide() end
  end
  if measureString and font then
    measureString:SetFontObject(font)
    measureString:SetWordWrap(false)
    -- An ascender and a descender on every line: the tallest the role can draw.
    measureString:SetText("Ayg" .. string.rep("\nAyg", lines - 1))
    height = measureString:GetStringHeight()
  end

  if type(height) ~= "number" or height < 1 then
    -- The font object's own point size, plus the leading the renderer adds.
    -- Only reached if the measurement above is unavailable.
    local size
    if font and type(font.GetFont) == "function" then
      local _, points = font:GetFont()
      size = tonumber(points)
    end
    height = lines * ((size or 10) + 2)
  end

  height = ceil(height)
  measuredHeights[key] = height
  return height
end

-- Every field caption on this screen is one unwrapped line of the `label` role,
-- and each is given this height explicitly (CreateFieldLabel) so the stack is
-- exactly as tall as the sum below says it is.
local function LabelHeight()    return TextHeight("label", 1) end
local function GuidanceHeight() return TextHeight("secondary", GUIDANCE_LINES) end

-- The message wrap at its floor: MESSAGE_MIN_LINES of the body font plus the
-- padding the wrap's border takes.
local function MessageMinHeight()
  return TextHeight("bodySmall", MESSAGE_MIN_LINES) + 2 * BODY_PAD
end

-- The "Attachments" caption's band, above the first row of slots.
local function SlotBandTop()
  return M.tightGap + LabelHeight() + M.tightGap
end

-- Rows of slots, with no trailing gap after the last one: the area used to
-- reserve a full ATTACH_ROW_STEP per row and so carried 4px of nothing along its
-- bottom edge.
local function ItemAreaHeight(rows)
  rows = max(1, tonumber(rows) or 1)
  return SlotBandTop() + rows * SLOT_SIZE + (rows - 1) * M.tightGap
end

-- Panel top down to the top of the message wrap.
local function TopBands()
  local caption = LabelHeight()
  return M.inset
       + caption + M.labelGap + M.controlHeight          -- recipient
       + BAR_GAP + BAR_H                                 -- category bar
       + SUBJECT_LABEL_GAP + caption + M.labelGap + M.controlHeight  -- subject
       + BAND_GAP + caption + M.labelGap                 -- message caption
end

-- The attachment area's bottom edge down to the panel's.
local function BottomBands()
  return M.tightGap + MONEY_ROW_H
       + M.tightGap + GuidanceHeight()
       + GUIDANCE_GAP + SEND_BUTTON_H
       + M.inset
end

-- THE SUM. Every fixed band, plus whatever the message body is given.
local function PanelHeightFor(bodyHeight, rows)
  return TopBands()
       + bodyHeight
       + BAND_GAP                    -- message body to attachments
       + ItemAreaHeight(rows)
       + BottomBands()
end

-- The panel height at which the message body is exactly at its floor. Public:
-- Core/MailboxUI.lua adds the window's own chrome to the taller of this and the
-- collect screen's own floor, so the window can never be dragged below what
-- either screen needs.
--
-- `rows` is the attachment rows currently showing, and the shell asks with the
-- live count: a second row of slots raises this by exactly the row it added, so
-- the window that grew to seat it cannot then be dragged back down onto the
-- message box.
function ST.MinPanelHeight(rows)
  return ceil(PanelHeightFor(MessageMinHeight(), rows))
end

-------------------------------------------------------------
-- 2. Small shared helpers
-------------------------------------------------------------

local POPUP_KEY = "POSTBOX_SEND_NOTICE"

-- The client's own dialog: it sits above everything, is keyboard-dismissable
-- and needs no skinning. Chat is the fallback only where the API is absent.
local function PopupNotice(message)
  local text = tostring(message or "")
  if type(StaticPopup_Show) == "function" and type(StaticPopupDialogs) == "table" then
    if not StaticPopupDialogs[POPUP_KEY] then
      StaticPopupDialogs[POPUP_KEY] = {
        text = "%s",
        button1 = L["POPUP_OK"],
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        -- No preferredIndex: STATICPOPUP_NUMDIALOGS no longer exists, and 12.x's
        -- StaticPopup does not read the field -- dialogs come from a shared
        -- pool, first free frame. See Core/CollectTab.lua's note.
      }
    end
    StaticPopup_Show(POPUP_KEY, text)
    return
  end
  if ns.Print then ns.Print(text) end
end

-- The live compose panel, or nil before the first mailbox has been opened.
--
-- There is one window and therefore one compose screen, but nothing outside the
-- shell holds a reference to it, so every entry point that is called from
-- elsewhere -- a reply from the mail detail, the recipient manager changing a
-- favourite, the resize grip releasing -- has to find it the same way.
local function ActivePanel()
  local UI = ns.MailboxUI
  local frame = UI and UI._frame
  return frame and frame.Tabs and frame.Tabs.send or nil
end

-- A frame whose size comes only from its anchors reports 0 until the first
-- layout pass, and this screen must be correct on the FIRST paint (nothing may
-- jump into place a frame after the window opens). `inset` is what the frame
-- gives up against its parent on each side, so the fallback is exact rather
-- than approximate.
local function ResolvedWidth(frame, parent, inset)
  local width = frame and type(frame.GetWidth) == "function" and frame:GetWidth() or 0
  if type(width) == "number" and width > 1 then return width end

  width = parent and type(parent.GetWidth) == "function" and parent:GetWidth() or 0
  if type(width) == "number" and width > 1 then return max(0, width - 2 * (inset or 0)) end

  return 0
end

-------------------------------------------------------------
-- 3. What is currently composed, and the money-state discipline
--
-- These readers are used by the guidance line on every keystroke AND by the
-- send itself, so they live in one place: a note that disagreed with what
-- actually goes into the mail would be worse than no note at all.
-------------------------------------------------------------

-- Items sitting in the send frame's attachment slots.
local function SlotHasItem(i)
  if type(HasSendMailItem) == "function" then
    return HasSendMailItem(i) and true or false
  elseif type(GetSendMailItem) == "function" then
    return GetSendMailItem(i) ~= nil
  end
  return false
end

local function AttachmentCount()
  local n = 0
  for i = 1, SEND_SLOT_COUNT do
    if SlotHasItem(i) then n = n + 1 end
  end
  return n
end

-- The quick-attach watcher (Core/MailboxUI.lua 5b) flips to this tab when the
-- count grows while the collect screen is up. It reads the count from here so
-- the two modules cannot disagree about what an attachment is.
function ST.GetAttachmentCount()
  return AttachmentCount()
end

-- The three money boxes as copper. What that copper MEANS depends on the
-- C.O.D. tick: attached gold when it is off, the price the recipient pays when
-- it is on.
local function ComposedCopper(panel)
  if not panel or not panel.GoldBox then return 0 end
  local gold   = tonumber(panel.GoldBox:GetText()) or 0
  local silver = (panel.SilverBox and tonumber(panel.SilverBox:GetText())) or 0
  local copper = (panel.CopperBox and tonumber(panel.CopperBox:GetText())) or 0
  return gold * 10000 + silver * 100 + copper
end

local function IsCODArmed(panel)
  return (panel and panel.CODCheck and panel.CODCheck:GetChecked()) and true or false
end

-- Zero the send frame's money/C.O.D. state.
--
-- Blizzard's send frame keeps whatever C.O.D. and attached-money values were
-- last set until something resets them, and Postbox never calls
-- ClearSendMail() -- that would detach the user's items. So a half-composed
-- C.O.D. mail that is abandoned must not be able to leave its value behind for
-- the next one. Attachments are deliberately left alone; only money is cleared.
local function ClearSendMailMoneyState()
  if type(SetSendMailCOD) == "function" then SetSendMailCOD(0) end
  if type(SetSendMailMoney) == "function" then SetSendMailMoney(0) end
end

-- Blank every composed field. Shared by ST.Reset and by the post-send cleanup,
-- which only runs once the send is KNOWN to have succeeded.
--
-- `keepRecipient` leaves the To: box alone -- the post-send cleanup passes
-- the option of that name, so a player mailing a run of things to one bank
-- alt is not made to address every one. ST.Reset never passes it: a fresh
-- mailbox visit starts from nothing, whatever the option says.
local function ClearDraftFields(panel, keepRecipient)
  if not panel then return end
  if not keepRecipient then
    panel.ToBox:SetText("")
    panel.ToBox:SetCursorPosition(0)
    ResetInlineCompletion(panel, "")
  end
  panel.SubjectBox:SetText("")
  panel.SubjectBox:SetCursorPosition(0)
  panel.BodyBox:SetText("")
  panel.BodyBox:SetCursorPosition(0)
  panel.GoldBox:SetText("")
  panel.SilverBox:SetText("")
  panel.CopperBox:SetText("")
  if panel.CODCheck then panel.CODCheck:SetChecked(false) end
  -- The placeholders answer to OnTextChanged, which SetText fires; this is only
  -- belt and braces for a field that was already empty.
  if panel.SubjectPlaceholder then panel.SubjectPlaceholder:Show() end
  if panel.BodyPlaceholder then panel.BodyPlaceholder:Show() end
end

-------------------------------------------------------------
-- 4. Refresh coalescing
--
-- Attaching one item can fire MAIL_SEND_INFO_UPDATE, ITEM_LOCK_CHANGED and
-- BAG_UPDATE within a few frames, and every one of them wants the slots
-- re-synced, the postage re-priced and the bag overlays re-marked. The previous
-- build answered each with its own C_Timer.After(0.05 / 0.1 / 0.15) -- a guess
-- at when the server had finished, one closure per event, and up to three
-- ContainerFrame_UpdateAll passes for one click.
--
-- Instead: mark what is stale and drain it once on the next frame. Events are
-- facts, so the events still drive it; only the *timing* guess is gone.
--
-- A hidden panel is never repainted. Its flags are kept and drained on show.
-------------------------------------------------------------

-- Forward declarations for the passes this coalescer drains that are defined
-- further down, next to the widgets they touch (sections 15b and 16b), plus the
-- one the category bar shares with the picker (section 14).
local ApplyElasticHeight, ContactsChanged, RefreshCategoryEmptiness

local function Drain(panel)
  panel._drainScheduled = false
  local dirty = panel._dirty
  if not dirty then return end

  -- Nothing on a hidden tab is worth repainting, and the bag overlays are
  -- already unmarked. Keep the flags: OnShow drains them.
  if not panel:IsShown() then return end

  if dirty.slots then
    dirty.slots = nil
    ST.RefreshAttachmentSlots(panel)
  end
  if dirty.bags then
    dirty.bags = nil
    ST.UpdateBagOverlays()
  end
  if dirty.cost then
    dirty.cost = nil
    ST.UpdateSendCost(panel)
  end
  if dirty.guidance then
    dirty.guidance = nil
    ST.UpdateSendGuidance(panel)
  end
  if dirty.contacts then
    dirty.contacts = nil
    ContactsChanged(panel)
  end
  -- Last, and deliberately: the window's height has to be asked for AFTER
  -- everything that can change how much room the message box has.
  if dirty.body then
    dirty.body = nil
    ApplyElasticHeight(panel)
  end
end

local function Invalidate(panel, what)
  if not panel then return end
  local dirty = panel._dirty
  if not dirty then dirty = {}; panel._dirty = dirty end
  dirty[what] = true

  if panel._drainScheduled then return end
  panel._drainScheduled = true
  -- One drain per frame, one closure per drain.
  C_Timer.After(0, function() Drain(panel) end)
end

-------------------------------------------------------------
-- 5. Attachment slots
--
-- One item slot: native empty-slot art, the icon, a stack count, a hover
-- highlight and an item tooltip. Nothing opaque is drawn over the art -- the
-- previous build laid down the art, shaded it, and then applied a full-alpha
-- card surface above both, so the art was dead pixels. Both host-UI skins
-- zeroed that texture, which is why it was never seen on a skinned setup.
--
-- Slots are NOT tagged __postboxPanel: an item slot with complete native art is
-- not one of the addon's themed containers. Theme.ApplySlot gives it the card
-- BORDER and nothing else.
-------------------------------------------------------------

-- Two shapes this file draws over and over: a texture held a fixed distance
-- inside its owner on every side, and the crop the client applies to icon art.
-- Blizzard's icon files carry their own border, and every icon in the game is
-- drawn with the outer 8 per cent cut away; a slot that skipped it would sit
-- visibly boxed-in beside the bags.
local function InsetTexture(texture, owner, inset)
  texture:SetPoint("TOPLEFT", owner, "TOPLEFT", inset, -inset)
  texture:SetPoint("BOTTOMRIGHT", owner, "BOTTOMRIGHT", -inset, inset)
end

local function CropIconBorder(texture)
  texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
end

local function CreateAttachmentSlot(parent, slotIndex)
  local slot = CreateFrame("Button", nil, parent, "BackdropTemplate")
  slot:SetSize(SLOT_SIZE, SLOT_SIZE)

  local col = (slotIndex - 1) % SEND_SLOTS_PER_ROW
  local row = floor((slotIndex - 1) / SEND_SLOTS_PER_ROW)
  slot:SetPoint("TOPLEFT", parent, "TOPLEFT",
                M.inset + col * SLOT_STEP_X,
                -SlotBandTop() - row * ATTACH_ROW_STEP)

  -- Under the item, outwards from the frame edge: the client's own empty-slot
  -- art, then a shade to lift an icon off it, then the skin's own border.
  slot.SlotBg = slot:CreateTexture(nil, "BACKGROUND", nil, -1)
  slot.SlotBg:SetAllPoints()
  slot.SlotBg:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
  CropIconBorder(slot.SlotBg)

  -- The shade is light on purpose: it has to let an item icon read against the
  -- slot art, not curtain the art off. `slotShade` exists in the palette for
  -- this one consumer, and anything opaque there loses the art again.
  slot.Shade = slot:CreateTexture(nil, "BACKGROUND", nil, 0)
  InsetTexture(slot.Shade, slot, 2)
  Theme.FillColor(slot.Shade, "slotShade")

  Theme.ApplySlot(slot)

  -- Hover feedback on its own layer, so the client shows and hides it and this
  -- file owns no mouse script for it.
  local highlight = slot:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetAllPoints()
  highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
  highlight:SetBlendMode("ADD")

  -- The item and its stack size. Both start hidden: an empty slot is the
  -- ordinary state, and RefreshAttachmentSlots is the only thing that reveals
  -- them.
  slot.Icon = slot:CreateTexture(nil, "ARTWORK")
  InsetTexture(slot.Icon, slot, 3)
  CropIconBorder(slot.Icon)
  slot.Icon:Hide()

  slot.Count = Theme.CreateText(slot, "numberSmall")
  slot.Count:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -2, 2)
  slot.Count:SetJustifyH("RIGHT")
  slot.Count:Hide()

  -- Right-click is what detaches, so the button has to accept both; the slot
  -- number rides on the frame because the handlers are shared across the band.
  slot.slotIndex = slotIndex
  slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  return slot
end

local function SyncAttachmentSlot(slot, slotIndex)
  if type(GetSendMailItem) ~= "function" then
    slot.Icon:Hide()
    slot.Count:Hide()
    slot.itemLink = nil
    return false
  end

  local name, _, texture, count = GetSendMailItem(slotIndex)
  if not (name and texture) then
    slot.Icon:Hide()
    slot.Count:Hide()
    slot.itemLink = nil
    return false
  end

  slot.Icon:SetTexture(texture)
  slot.Icon:SetDesaturated(false)
  slot.Icon:Show()
  slot.itemLink = (type(GetSendMailItemLink) == "function") and GetSendMailItemLink(slotIndex) or nil

  if count and count > 1 then
    slot.Count:SetText(count)
    slot.Count:Show()
  else
    slot.Count:Hide()
  end
  return true
end

-- Re-reads every slot from the send frame and reveals exactly as many boxes as
-- the user needs to see. Never assumes slot n still holds what it held a moment
-- ago: attaching and detaching compacts the others.
function ST.RefreshAttachmentSlots(panel)
  if not panel or not panel.ItemSlots then return end

  -- A slot that has just come free is the queue's to fill (section 18a).
  -- Before the read below, so the slots are drawn as they now stand.
  if TopUpFromQueue then TopUpFromQueue(panel) end
  if RefreshQueueLabel then RefreshQueueLabel(panel) end

  local highest = 0
  for i = 1, SEND_SLOT_COUNT do
    local slot = panel.ItemSlots[i]
    if slot and SyncAttachmentSlot(slot, i) then highest = i end
  end

  -- One full row by default, then one trailing empty slot as attachments grow,
  -- up to the client's limit: 6 boxes at 0-5 attached, 7 once the row fills,
  -- ... 12 once 11 are attached.
  local visible = min(SEND_SLOT_COUNT, max(SEND_SLOTS_PER_ROW, highest + 1))
  for i = 1, SEND_SLOT_COUNT do
    local slot = panel.ItemSlots[i]
    if slot then slot:SetShown(i <= visible) end
  end

  local rows = ceil(visible / SEND_SLOTS_PER_ROW)
  panel._attachRows = rows
  if panel.ItemArea then
    panel.ItemArea:SetHeight(ItemAreaHeight(rows))
  end

  -- A second row makes the WINDOW taller rather than stealing height from the
  -- message body, and raises the window's FLOOR by the same amount so it cannot
  -- then be dragged back down onto the body. Only while this tab is actually
  -- shown: a background refresh must not resize the window out from under the
  -- collect screen.
  local UI = ns.MailboxUI
  if panel:IsShown() and UI and UI.SetAttachmentRows then
    UI.SetAttachmentRows(rows)
  end

  -- The body is anchored above the area that just changed height.
  ST.ApplyBodyBounds(panel)
  -- The row moved the window's bottom edge down the screen, so how much of the
  -- message fits -- and how much room there is left to grow into -- has to be
  -- re-asked. Coalesced rather than immediate: the layout it measures has not
  -- settled yet.
  Invalidate(panel, "body")

  -- Every path that changes the attachments comes through here, so this is the
  -- one place the guidance line has to be re-asked for them.
  ST.UpdateSendGuidance(panel)
end

-------------------------------------------------------------
-- 6. Postage
-------------------------------------------------------------

function ST.UpdateSendCost(panel)
  local label = panel and panel.SendCostLabel
  if not label then return end

  if type(GetSendMailPrice) ~= "function" then
    label:SetText("")
    return
  end

  local cost = GetSendMailPrice() or 0
  if cost <= 0 then
    -- Nothing composed yet. Say nothing rather than invent an amount: the
    -- previous build substituted 30 copper, which was a number the user had no
    -- way to check.
    label:SetText("")
    return
  end

  -- Postage is not an error. It used to be wrapped in a red escape, so normal
  -- 30-copper postage read as a failure; the label's own `secondary` role now
  -- carries it.
  label:SetText(L["LABEL_SEND_COST"] .. ns.Core.Formatting.FormatMoneyIcons(cost))
end

-------------------------------------------------------------
-- 7. Send guidance
--
-- One quiet line above the Send button saying what the game is going to do with
-- this mail: when it should turn up and -- for the cases Postbox can call with
-- confidence -- that it may not turn up at all. "Why hasn't my mail arrived"
-- and "why did my cross-realm mail bounce" are the two questions the mail UI
-- has never answered, and both are answerable here, before the send.
--
-- Core/MailRules.lua owns every rule and cites its source for each; this
-- function only paints what that module returns. It NEVER disables the Send
-- button and never refuses anything -- see MailRules' header for why a false
-- refusal is the expensive mistake.
--
-- It reads the composed state through the same helpers DoSendMail uses.
-------------------------------------------------------------

-- Grey for "here is what will happen", amber for "this may not work". Not red:
-- red in this window means an error that has already happened, and nothing here
-- has happened yet.
local GUIDANCE_TOKEN = {
  info = "textSecondary",
  warn = "warning",
}

-- Reused rather than rebuilt on every keystroke.
local guidanceCtx = {}

function ST.UpdateSendGuidance(panel)
  local label = panel and panel.GuidanceLabel
  if not label then return end

  local MR = ns.MailRules
  local assessment
  if type(MR) == "table" and type(MR.Inspect) == "function" then
    guidanceCtx.items = AttachmentCount()
    guidanceCtx.money = ComposedCopper(panel)
    guidanceCtx.cod   = IsCODArmed(panel)
    assessment = MR.Inspect(panel.ToBox:GetText(), guidanceCtx)
  end

  local note = assessment and assessment.guidance
  if not note then
    -- Nothing worth saying (no recipient yet, or a plain letter to somebody on
    -- this realm) leaves the band empty rather than filling it with filler. A
    -- line that is always on screen is a line nobody reads.
    label:SetText("")
    return
  end

  -- note.value is a format argument where the rule quotes a number (the C.O.D.
  -- cap); ns.L's __call is the formatting form.
  if note.value ~= nil then
    label:SetText(L(note.key, note.value))
  else
    label:SetText(L[note.key])
  end

  Theme.SetColor(label, GUIDANCE_TOKEN[note.severity] or GUIDANCE_TOKEN.info)
end

-------------------------------------------------------------
-- 8. The send lifecycle
--
-- SendMail() is asynchronous: MAIL_SEND_SUCCESS or MAIL_FAILED arrives a moment
-- later. Clearing the composed draft before we know which one came back loses
-- everything the user typed when the send fails -- and a mistyped recipient is
-- the common case -- so the draft is held until success is CONFIRMED.
--
-- Neither event is guaranteed to arrive, so a timeout always restores the UI to
-- a usable state; it just keeps the draft rather than clearing it. Worst case
-- the user sees a still-filled form for a mail that did go out, which they can
-- see in their sent history and clear themselves. The reverse is unrecoverable.
-------------------------------------------------------------

local SEND_TIMEOUT = 10

-- { panel = <frame>, toName = <string>, token = <number> } while in flight.
local pendingSend = nil
local sendToken = 0

-- "Send mail", or "Send 3 mails" when the attachment queue (section 18a)
-- means one press posts more than one.
local function SendButtonCaption(panel)
  local queue = panel and panel._queue
  local waiting = queue and #queue or 0
  if waiting > 0 then
    return ns.Plural("BTN_SEND_MAILS", 1 + math.ceil(waiting / SEND_SLOT_COUNT))
  end
  return L["BTN_SEND_MAIL"]
end

local function SetSendButtonBusy(panel, busy)
  local button = panel and panel.FillButton
  if not button then return end
  if busy then
    if button.Disable then button:Disable() end
    button:SetText(L["BTN_SEND_MAIL_PENDING"])
  else
    if button.Enable then button:Enable() end
    button:SetText(SendButtonCaption(panel))
  end
end

-- Drop the in-flight bookkeeping WITHOUT touching the draft. Used by ST.Reset,
-- so a mailbox close/open cycle can never leave the Send button stuck disabled.
local function AbandonPendingSend(panel)
  if pendingSend and (not panel or pendingSend.panel == panel) then
    pendingSend = nil
  end
  if panel then SetSendButtonBusy(panel, false) end
end

-- The draft after the LAST mail of a press has gone: blanked, apart from the
-- recipient when the option says to keep it.
local function SettleDraftAfterSuccess(panel)
  local UI = ns.MailboxUI
  local keep = UI ~= nil and type(UI.GetOption) == "function" and UI.GetOption("keepRecipient")
  ClearDraftFields(panel, keep)
  ClearSendMailMoneyState()
end

-- outcome: "success" | "failed" | "timeout"
local function FinishSend(outcome)
  local pending = pendingSend
  if not pending then return end
  pendingSend = nil

  local panel = pending.panel
  SetSendButtonBusy(panel, false)

  if outcome == "success" then
    -- History is written here and nowhere else: a recipient the server refused
    -- is not a recipient the player has mailed.
    Contacts().SaveRecipient(pending.toName)
    -- Attachments still queued: the next mail goes out from here and the
    -- draft stands until the last one has. ContinueQueue settles it itself.
    if ContinueQueue(panel, pending) then return end
    SettleDraftAfterSuccess(panel)
  elseif outcome == "timeout" then
    PopupNotice(L["MSG_SEND_TIMEOUT"])
  else
    -- The client already shows its own red error for the underlying reason;
    -- this only tells the user their draft is still there.
    if ns.Print then ns.Print(L["MSG_SEND_FAILED"]) end
  end

  Invalidate(panel, "slots")
  Invalidate(panel, "cost")
  Invalidate(panel, "guidance")
end

-- What a compose field actually holds, with the whitespace around it gone.
-- Every read of the draft goes through here, so a box holding nothing but
-- spaces counts as empty in all three checks below rather than in some of them.
local function FieldText(box)
  return Helpers().NormalizeText(box:GetText())
end

local function DoSendMail(panel)
  local toName  = FieldText(panel.ToBox)
  local subject = FieldText(panel.SubjectBox)
  local body    = FieldText(panel.BodyBox)

  if toName == "" then PopupNotice(L["ERR_NO_RECIPIENT"]) return end
  if subject == "" then subject = L["DEFAULT_NO_SUBJECT"] end

  if type(SendMail) ~= "function" then
    PopupNotice(L["ERR_SENDMAIL_UNAVAILABLE"])
    return
  end

  local totalCopper = ComposedCopper(panel)
  local attachments = AttachmentCount()

  -- Both C.O.D. and attached money are set explicitly on EVERY send: to the
  -- value in use, and to 0 for the one that is not. The send frame's money
  -- state otherwise persists between mails, so an unticked C.O.D. box that
  -- never zeroed the value would let a previous mail's C.O.D. (or gold) ride
  -- along on this one. The unused field is zeroed first, which is the order
  -- Blizzard's own send frame uses.
  if IsCODArmed(panel) then
    if attachments <= 0 then
      PopupNotice(L["ERR_COD_NO_ATTACHMENT"])
      return
    end
    if totalCopper <= 0 then
      PopupNotice(L["ERR_COD_ZERO_PRICE"])
      return
    end
    if type(SetSendMailCOD) ~= "function" then
      PopupNotice(L["ERR_COD_API_UNAVAILABLE"])
      return
    end
    if type(SetSendMailMoney) == "function" then SetSendMailMoney(0) end
    SetSendMailCOD(totalCopper)
  else
    if type(SetSendMailCOD) == "function" then SetSendMailCOD(0) end
    if type(SetSendMailMoney) == "function" then SetSendMailMoney(totalCopper) end
  end

  -- Hold the draft until the server confirms. FinishSend clears it on success,
  -- keeps it on failure, and the timeout below guarantees the button comes
  -- back either way. The token is what stops a stale timeout from settling a
  -- later send.
  sendToken = sendToken + 1
  local myToken = sendToken
  pendingSend = { panel = panel, toName = toName, token = myToken }
  SetSendButtonBusy(panel, true)

  SendMail(toName, subject, body)

  C_Timer.After(SEND_TIMEOUT, function()
    if pendingSend and pendingSend.token == myToken then
      FinishSend("timeout")
    end
  end)
  -- Success stays quiet: a popup on the normal path is a popup people learn to
  -- dismiss without reading.
end

-------------------------------------------------------------
-- 9. Recipient display and insertion
--
-- Two different strings, and conflating them is what made Postbox offer an
-- unmailable name:
--
--   what is DRAWN     the name, class-coloured, with any realm half dimmed
--                     behind it, so a list of a hundred guildmates still reads
--                     as a list of names.
--   what is INSERTED  the full address, always. A bare name in the To: box
--                     means "on my realm", so for an off-realm character the
--                     realm suffix is not decoration -- drop it and the mail
--                     goes to somebody else, or nowhere.
--
-- ns.Recipients.Display owns the second rule and nothing here re-derives it.
-------------------------------------------------------------

-- "Bob-Draenor" -> class-coloured "Bob" plus a grey realm half. The class is
-- looked up by the FULL address (the cache is keyed on name AND realm), so a
-- same-named character from another realm is not handed the wrong colour.
-- Core/RecipientManager.lua draws its rows the same way.
local function DecorateAddress(address)
  local text = tostring(address or "")
  local short, realm = text:match("^([^%-]+)%-(.+)$")
  if short then
    return Contacts().GetClassColoredName(text, short)
        .. Theme.Colorize("textSecondary", "-" .. realm)
  end
  return Contacts().GetClassColoredName(text)
end

-- The one route into the To: box. Everything -- the picker, the type-ahead, a
-- reply from the detail view -- goes through it, so no caller can insert a raw
-- collected string and lose a realm suffix.
function ST.SetRecipient(panel, name)
  if not panel or not panel.ToBox then return end
  local R = ns.Recipients
  local value = tostring(name or "")
  if type(R) == "table" and type(R.Display) == "function" then
    local resolved = R.Display(value)
    if resolved ~= "" then value = resolved end
  end
  panel.ToBox:SetText(value)
  panel.ToBox:SetCursorPosition(#value)
  -- A picked name is a finished answer, not a half-typed one: whatever the
  -- inline completion was offering is gone, and the box now holds text the
  -- player did not type a character of. Section 15a measures the next keystroke
  -- against THIS, so an edit to the end of a picked name still completes.
  ResetInlineCompletion(panel, value)
end

-- Reply, from the mail detail view. The compose screen owns its own fields, so
-- the detail asks for a reply rather than writing the boxes itself -- which is
-- also what routes the sender's name through the address rule above. Replying
-- to an off-realm sender whose realm suffix had been dropped addressed the mail
-- to whoever holds that name on the player's own realm.
--
-- The body is deliberately left empty: its placeholder already reads as an
-- invitation to type, and prefilling it means a reply that says "Enjoy!"
-- because nobody cleared it.
function ST.PrepareReply(recipient, subject)
  local panel = ActivePanel()
  if not panel then return end

  ST.SetRecipient(panel, recipient)

  if panel.SubjectBox then
    panel.SubjectBox:SetText(subject or "")
    panel.SubjectBox:SetCursorPosition(0)
  end
  if panel.BodyBox then
    panel.BodyBox:SetText("")
    panel.BodyBox:SetCursorPosition(0)
    panel.BodyBox:SetFocus()
  end

  ST.UpdateSendGuidance(panel)
end

-- Two lists this addon owns must never be on screen at once: the type-ahead
-- popup and the contact picker appear under the same field, within a second of
-- each other, and overlapping them makes both unreadable.
local function CloseOtherLists(panel, keep)
  if panel.SuggestFrame and keep ~= panel.SuggestFrame then panel.SuggestFrame:Hide() end
  if panel.ContactPicker and keep ~= panel.ContactPicker then panel.ContactPicker:Hide() end

  local Dropdown = ns.Core and ns.Core.UI and ns.Core.UI.Dropdown
  if Dropdown and Dropdown.CloseAll then Dropdown.CloseAll() end
end

-- Every list this screen can open, closed because the window changed size.
--
-- All three are popups anchored to a control that has just moved and sized from
-- a width that has just changed: the picker measures itself against the
-- category bar and the window's own top and bottom edges, the type-ahead spans
-- the recipient field, and the shared select control's list hangs off its
-- toggle. Left open through a drag-resize each one sits at the geometry it was
-- opened at, which reads as a detached panel floating over the window.
--
-- WHAT THIS DELIBERATELY DOES NOT TOUCH: the recipient box. Somebody dragging
-- the window mid-sentence must not lose their focus or their text, so nothing
-- here calls ClearFocus or SetText. The type-ahead's debounce token IS bumped,
-- because otherwise a pass scheduled a moment before the drag reopens the popup
-- 150ms into it -- at which point closing it was pointless. The next keystroke
-- schedules a fresh pass and it comes back, correctly placed.
local function CloseListsForResize(panel)
  -- The message box growing under the cursor is NOT one of those resizes. The
  -- window's top-left has not moved, so nothing the player opened has moved out
  -- from under them, and closing the list they are reading -- or cancelling the
  -- type-ahead pass for the name they are halfway through typing -- is exactly
  -- the interruption the elastic window exists to avoid. Section 16b stamps the
  -- frame it grew on; this is the same frame if we are inside that growth.
  local grewAt = panel._autoGrowAt
  if grewAt and type(GetTime) == "function" and GetTime() == grewAt then return end

  local sf = panel.SuggestFrame
  if sf and sf:IsShown() then
    panel._suggestToken = (panel._suggestToken or 0) + 1
    sf:Hide()
  end

  -- Its OnHide clears the category bar's active tile, so the bar cannot be left
  -- marking a list that is no longer on screen.
  local picker = panel.ContactPicker
  if picker and picker:IsShown() then picker:Hide() end

  local Dropdown = ns.Core and ns.Core.UI and ns.Core.UI.Dropdown
  if Dropdown and Dropdown.CloseAll then Dropdown.CloseAll() end
end

-------------------------------------------------------------
-- 10. Sorting for a browsable list
--
-- Names are sorted for the eye, not for the byte: accented letters group with
-- their base letter and Cyrillic sorts as Cyrillic, so a French or Russian
-- roster reads as one alphabet rather than two.
--
-- The fold that does that belongs to Core/ContactService.lua, next to the names
-- it describes, and is PRECOMPUTED there once per entry (`entry.fold`) with a
-- memo behind it for the names that reach no source -- the player's own stored
-- favourites. It used to live here and run INSIDE the comparator: eight gsub
-- passes plus an upper, twice per comparison, which on a 900-member guild is
-- roughly 160,000 transient strings for one click on the Guild tile, and again
-- on every right-click favourite toggle because that repopulates in place.
-------------------------------------------------------------

-- Decorate, sort, undecorate. `sortKeys` is filled once per entry before the
-- sort -- N memo lookups -- so the comparator itself allocates nothing and
-- calls nothing.
local sortScratch, sortKeys = {}, {}

local function SortKeyLess(a, b)
  local af, bf = sortKeys[a], sortKeys[b]
  -- Byte order within a folded tie, so the sort stays total and stable.
  if af == bf then return a < b end
  return af < bf
end

-- Sorts a COPY, and that is load-bearing: the contact service's buckets are its
-- own arrays, reused across queries and handed out by reference, so sorting one
-- in place would reorder the service's cache from a draw call.
--
-- `recent` is deliberately in recency order end to end, which is why the recent
-- section is never passed through here at all -- see PICKER_SECTIONS' `ordered`
-- flag and the populate loop that honours it.
local function SortForDisplay(entries)
  local CS = Contacts()
  -- string.upper is not the same collation, only a safe one: it is reached
  -- solely if the contact service is somehow unavailable, in which case there
  -- is nothing to sort either.
  local fold = (type(CS) == "table" and type(CS.Fold) == "function") and CS.Fold or string.upper

  local copy = sortScratch
  for i = #copy, 1, -1 do copy[i] = nil end
  for key in pairs(sortKeys) do sortKeys[key] = nil end

  for i = 1, #entries do
    local name = entries[i]
    copy[i] = name
    sortKeys[name] = fold(name)
  end

  table.sort(copy, SortKeyLess)
  return copy
end

-------------------------------------------------------------
-- 11. Curation strings
--
-- ns.L's __index returns the key itself for anything missing, which would put a
-- raw "CONTACT_..." on screen, so probe the table directly and fall back to the
-- client's own (already localised) global strings.
-------------------------------------------------------------

local function Localized(key, fallback)
  local value = rawget(L, key)
  if type(value) == "string" and value ~= "" then return value end
  return fallback
end

local function RightClickText() return KEY_BUTTON2 or "Right Click" end

-- "Right Click: Favourites"
local function FavHintText()
  return Localized("CONTACT_FAV_HINT", RightClickText() .. ": " .. L["CONTACT_FAVORITES"])
end

-- "Shift + Right Click: Hide"
local function HideHintText()
  return Localized("CONTACT_HIDE_HINT",
    (SHIFT_KEY_TEXT or "Shift") .. " + " .. RightClickText() .. ": " .. (HIDE or "Hide"))
end

-------------------------------------------------------------
-- 12. The favourite star
--
-- The art, the atlas probe and the empty-state tint are all Core/Theme.lua's --
-- the recipient manager draws the same star, and the two windows have to agree
-- about what a favourite looks like. The reasoning for the artwork and for why
-- neither state is ever faded lives there, next to the code it explains.
--
-- Aliased rather than called through Theme at each site: this file names the
-- control a favourite icon, and the four call sites below read better for it.
-------------------------------------------------------------

local ApplyFavoriteIcon = Theme.SetStarArt

-- Reads the stored rows directly rather than calling R.Favorites(): the state
-- map is sparse (only recipients with non-default state have a row), and this
-- never calls R.Key, which must not run before the realm name is known (see
-- Core/Recipients.lua). The manager counts the same field the same way, so the
-- two windows never disagree about how many favourites there are.
local function FavoriteCount()
  local R = ns.Recipients
  if type(R) ~= "table" or type(R.ForEach) ~= "function" then return 0 end
  local count = 0
  R.ForEach(function(_, row)
    if row.fav then count = count + 1 end
  end)
  return count
end

-------------------------------------------------------------
-- 13. The recipient category bar
--
-- A strip directly under the recipient field: a favourites star pinned left,
-- and five named categories -- Recent, Alts, Friends, Guild, All -- tiling
-- everything the star leaves. One click opens the list you actually want --
-- there is no "open a picker, then choose a category inside it" step.
--
-- The star is the only member that is not a word, because it is the only one
-- whose meaning a single glyph carries outright and the only one that counts
-- what is behind it. Everything else is a caption, in the same words the
-- recipient manager's filter row uses.
--
-- The bar replaced the picker's own filter tabs, so it has to say which
-- category is OPEN, not merely which one the mouse is over. Hover and active
-- are therefore tracked separately and active wins, otherwise OnLeave would
-- wipe the only indication of what the list below is showing.
--
-- THE PLATES ARE THE THEME'S, not this file's. Every tile and the star are
-- Theme.CreatePlate(bar, "tile"), which is the same control the window tabs and
-- the collect screen's view segments are drawn from.
--
-- This is the fix for the defect the bar was reported for. It used to paint its
-- own plates: `_bg:SetColorTexture(1, 1, 1, fill)` at fill 0.10 / 0.17 / 0.26,
-- i.e. white at a tenth to a quarter of an alpha -- 74% to 90% SEE-THROUGH. On
-- an opaque window that reads as a faint wash; under EllesmereUI, where the
-- window follows the user's own opacity setting, there was nothing behind it
-- and the game world rendered straight through the bar, under captions the
-- player then had to read against moving scenery.
--
-- The factory's ladder is the opposite: it rises in colour AND alpha together,
-- from 0.94 idle to 0.99 selected, so the more prominent state is always the
-- more SUBSTANTIAL one and even an idle tile brings its own ground. It also
-- carries the 1px ring, the lit top bevel, the hover wash and the caption tones
-- this file used to reimplement, and it files every texture it owns in
-- `__pbPlateArt` so a host-UI skin can retire the lot in one call.
--
-- The factory publishes its fill as `_bg` under exactly the name the hand-
-- rolled bar gave it, which is why adopting it here was a deletion rather than
-- a rewrite. Nothing below reaches for that texture; it is named for the
-- benefit of anything that still does.
-------------------------------------------------------------

-- BAR_H lives in section 1 with the other band heights.
-- A width, not a height: the star is square-ish at the tile height and there is
-- no width token, because a width that must seat a 14px glyph plus its padding
-- is not on the spacing ladder.
local BAR_ICON_W    = 24
local BAR_ICON_SIZE = M.iconSize            -- 14
-- Tile to tile inside one dense strip: the ladder's smallest rung, the same one
-- BAR_GAP uses to bind the bar to the field above it.
local BAR_TILE_GAP  = M.space.hair

-- The star is the one button that changes size: with favourites it shows how
-- many, so the two states differ by CONTENT and not merely by the shade of a
-- 14px glyph. BAR_ICON_PAD is the padding each side of the CONTENT -- glyph
-- alone, or glyph plus count -- so the button is never narrower than the empty
-- state and the content always sits centred in whatever width it ends up with.
-- Derived, not written: it is exactly half the leftover at the empty width, so
-- the two cannot drift if either the button or the glyph is ever resized.
local BAR_ICON_PAD  = floor((BAR_ICON_W - BAR_ICON_SIZE) / 2)
local BAR_COUNT_GAP = M.space.hair
-- The cap on that count is Theme.CountCap: the five word tiles share whatever
-- the star leaves them, and the recipient manager's star has the same problem.
-- The width is still measured from the rendered string, so nothing clips
-- whatever the number turns out to be.

-- THE STAR AND ITS COUNT ARE ONE OBJECT, and it is centred as one.
--
-- The count is a number the player has not seen before -- none, "1", "23" --
-- so its width is not knowable in advance and cannot be reserved. The previous
-- layout pinned the glyph a fixed pad from the LEFT edge and grew the button
-- rightwards to seat the number, which centres the pair only for as long as the
-- number measures exactly what the button was widened by. Under a host UI that
-- re-fonts our text after we measured it, it does not, and the star ends up
-- hard against the left edge with the number hanging off the right.
--
-- So both halves come from one measurement, taken at the moment the count is
-- set: the group's width decides the button's width, and the group is then
-- placed at half the leftover. With no count that is the empty state's own
-- padding to the pixel, so nothing moves when there is nothing to count.
--
-- Called from RefreshContactBar, which is the one place the count changes.
local function LayoutFavoriteGroup(star)
  local icon = star and star.Icon
  if not icon then return end

  local count = star.Count
  local countWidth = 0
  if count and count:IsShown() then
    countWidth = ceil(count:GetStringWidth() or 0)
  end

  local group = BAR_ICON_SIZE + ((countWidth > 0) and (BAR_COUNT_GAP + countWidth) or 0)
  -- Never narrower than the glyph's own button: a one-digit count must not
  -- produce a star smaller than the one standing beside it a moment ago.
  local width = max(BAR_ICON_W, group + 2 * BAR_ICON_PAD)
  star:SetWidth(width)

  icon:ClearAllPoints()
  icon:SetPoint("LEFT", star, "LEFT", floor((width - group) / 2), 0)
end

-- Repaints one bar button from its own state. The plate itself is entirely the
-- theme's: `flagged` is the star with favourites behind it (one step up from
-- idle, so selection still wins), `selected` is the category whose list is
-- open, and the caption tones follow from those without being named here.
--
-- What is left is the ONE fact the plate factory cannot know: the category
-- behind this tile is EMPTY. A property of the data, not of the control, so it
-- has to be re-applied after every repaint the factory makes -- including the
-- hover repaints, which is why this is called from the bar's OnEnter and
-- OnLeave as well as from the style pass below.
--
-- The tile stays clickable and keeps its plate: the empty state it opens
-- explains the category better than a dead button would, and a disabled control
-- cannot say WHY it is disabled. Only the caption drops to the disabled tone.
-- This is the recipient manager's rule (TintEmptyCaption there); the two bars
-- sit under the same star, name the same categories, and now agree about which
-- of them have anything behind them.
--
-- The star is exempt in both windows: its empty state is different ARTWORK
-- (a hollow outline instead of a filled star), not a fainter version of the
-- same glyph. It is also the only member of the bar without a caption, which is
-- why this reaches for `Text` alone -- every other tile now wears a word.
local function TintEmptyCaption(b)
  if not b or b._isStar or not b._empty or b._active then return end
  Theme.DimCaption(b)
end

local function StyleBarButton(b)
  if not b then return end
  -- Flagged then selected, and the caption tint last of all. Theme.SetTileState
  -- owns that order because the recipient manager's bar depends on it too.
  Theme.SetTileState(b, b._active, b._isStar and b._hasFavorites)
  TintEmptyCaption(b)
end

local FavoriteCountText = Theme.CountBadgeText

-- Tile widths come from the panel width, so no caption here carries a fixed
-- width. When a translated label is still too long for its share, Theme.FitText
-- truncates it and records the full text; the tile's own OnEnter puts that in a
-- tooltip. Truncate-with-a-tooltip is the last step of the theme's fit rule and
-- the only one a tile with an optional label is allowed to take.
local function FitTileLabel(b, width)
  if not b or not b.Text then return end
  Theme.FitText(b.Text, max(width - 2 * M.tightGap, 1), b._label, b)
end

-- Derives every tile's edges from the usable width rather than rounding one
-- shared width n times: the latter loses up to n-1 px and the last tile then
-- stops short of the button on its right.
local function LayoutContactBar(panel)
  local bar = panel and panel.ContactBar
  if not bar then return end

  -- The bar spans the recipient field, which is inset one margin each side of
  -- the panel. Falling back to that is what makes the FIRST paint correct:
  -- an anchored width reads 0 until the first layout pass, and the previous
  -- build's answer was a deferred timer, so six controls visibly jumped into
  -- place a frame after the window opened.
  local width = ResolvedWidth(bar, panel, M.inset)
  if width < 40 then return end

  local tiles = panel.ContactTiles
  local count = #tiles
  if count == 0 then return end

  -- The star is the one fixed-width member of the bar, and its width tracks its
  -- favourite count, so read it rather than assuming the no-count width.
  -- Everything else -- All included -- is a tile sharing what is left.
  local star = panel.FavoriteButton
  local lead = ((star and star:GetWidth()) or BAR_ICON_W) + BAR_TILE_GAP

  local usable = width - lead
  if usable < count then return end

  panel._barColumns = Theme.ColumnEdges(usable, count, BAR_TILE_GAP, panel._barColumns)
  local columns = panel._barColumns

  for i = 1, count do
    local column = columns[i]
    local b = tiles[i]
    b:ClearAllPoints()
    b:SetWidth(max(column.width, 1))
    b:SetPoint("TOPLEFT", bar, "TOPLEFT", lead + column.left, 0)
    FitTileLabel(b, column.width)
  end
end

-- Mirrors the picker's state onto the bar: which category is open, and how many
-- favourites there are.
local function RefreshContactBar(panel)
  if not panel or not panel.ContactButtons then return end

  local picker = panel.ContactPicker
  local active = (picker and picker:IsShown()) and (picker.Filter or "all") or nil

  for _, b in ipairs(panel.ContactButtons) do
    b._active = (b._catId == active)
    StyleBarButton(b)
  end

  local star = panel.FavoriteButton
  if star then
    local count = FavoriteCount()
    star._favoriteCount = count
    star._hasFavorites = count > 0
    -- Active regardless of the count: the star opens the list either way, so an
    -- open-but-empty favourites view still has to say that it is the open one.
    star._active = (active == "favorites")
    ApplyFavoriteIcon(star.Icon, star._hasFavorites)

    local text = FavoriteCountText(count)
    if text and star.Count then
      star.Count:SetText(text)
      star.Count:Show()
    elseif star.Count then
      star.Count:Hide()
    end
    -- Both the button's width and the glyph's position, from one measurement of
    -- what is actually on the button.
    LayoutFavoriteGroup(star)
    StyleBarButton(star)
  end

  -- The star's width is the tiles' left edge, so a changed count re-tiles the
  -- rest of the bar.
  LayoutContactBar(panel)
end

-- Public, for the recipient manager: it favourites and unfavourites in a window
-- of its own, which can be open beside the mailbox, and the star on this bar
-- shows a count that would otherwise sit there wrong until the tab was next
-- shown. Nothing else holds a reference to the panel, so it is reached through
-- MailboxUI; a mailbox that has never been opened simply has nothing to update.
function ST.RefreshRecipientBar()
  local panel = ActivePanel()
  if panel then RefreshContactBar(panel) end
end

-------------------------------------------------------------
-- 14. The contact picker
--
-- A Postbox-owned scrolling panel rather than a Blizzard context menu. The
-- client's menu frames are Compositor-guarded and their submenu panels can only
-- be reached through an API that taints Blizzard's menu pipeline, so a nested
-- category > name menu rendered with no background we were permitted to draw.
-- Owning the frame means we control its opacity, it is skinned with the rest of
-- the addon, and the whole list is visible at once. See COMBAT_TAINT.md.
-------------------------------------------------------------

local ROW_H       = M.listRowHeight   -- 18
local ROW_INDENT  = 14                -- names indent under a flush-left heading
local HEADER_H    = 17
local HEADER_GAP  = M.gap             -- air above every group but the first
local PICKER_PAD  = 5
local PICKER_GAP  = 2                 -- between the bar and the panel it opens
local PICKER_MIN_W, PICKER_MAX_H, PICKER_MIN_H = 220, 320, 80
-- The picker may not touch the window's own edge.
local PICKER_EDGE_PAD = 6

-- How many of the Recent list the ALL view shows. Recent is a shortcut to the
-- top of the mail history there, not a second copy of it: six names is about
-- who a player is actually corresponding with this session, and it keeps the
-- unfiltered view from opening on a wall of one category. Clicking the Recent
-- tile shows the whole list, uncapped.
local RECENT_PICKER_MAX = 6

-- Section order in the unfiltered view. Hoisted: rebuilding it per populate is
-- six tables and six locale lookups for a list that never changes.
--
-- THE ORDER IS THE CATEGORY BAR'S, deliberately: star, Recent, Alts, Friends,
-- Guild. The bar above the picker and the recipient manager's bar already agree
-- with each other; this used to agree with neither, and led with a heading
-- ("Recent alliance") that appeared on no bar at all.
--
--   `ordered`  the source arrives in a meaningful order of its own and must NOT
--              be alphabetised. Mail history is the only one.
--   `max`      a cap applied in the ALL view only (see the populate loop).
--
-- Two of the service's eight lists deliberately get no section:
--
--   `grouped`  C_RecentAllies. Kept as a source because those people are
--              mailable and it costs one pcall per mailbox open, and it feeds
--              the type-ahead where a half-remembered name from last night's
--              dungeon is genuinely useful. But it is not a list anybody
--              BROWSES to address a letter, and as a second heading under
--              Recent it was a group reachable no other way.
--   `other`    the client's own autocomplete leftovers, which are always empty
--              for the empty query this picker asks with.
--
-- `manual` DOES get one: those are recipients added by hand in the manager and
-- since un-favourited, so no live source knows about them and without a section
-- here they are reachable only from the other window.
--
-- Membership across the service's lists is no longer exclusive, so the All view
-- can show a guildmate you mailed yesterday under both Recent and Guild. That
-- is correct and left alone: Recent is a six-name shortcut, Guild is the
-- roster, and a person legitimately answers to both. The cap is what keeps the
-- repetition to at most six names.
local PICKER_SECTIONS = {
  { key = "favorites", titleKey = "CONTACT_FAVORITES" },
  { key = "recent",    titleKey = "CONTACT_RECENT", ordered = true, max = RECENT_PICKER_MAX },
  { key = "alts",      titleKey = "CONTACT_ALTS" },
  { key = "friends",   titleKey = "CONTACT_FRIENDS" },
  { key = "guild",     titleKey = "CONTACT_GUILD" },
  { key = "manual",    titleKey = "CONTACT_MANUAL" },
}

-- WHICH TILES HAVE NOTHING BEHIND THEM.
--
-- Declared here, with the section table it reads, because the picker and the
-- category bar have to agree: a tile is empty exactly when the list it opens
-- would be. The bar's own repaint (RefreshContactBar) only READS the verdict --
-- it runs on every open, close and favourite toggle and must stay a repaint --
-- so the verdict is recomputed only where a snapshot is being built anyway:
-- the picker's populate, the tab being shown, and the contacts listener in
-- section 15b. `results` is that snapshot where the caller already has one.
--
-- LOADING IS NOT EMPTY. The guild roster and the friends list arrive from the
-- server a moment after login; dimming a guild tile for that moment and
-- undimming it a second later is worse than never dimming it. While the service
-- says its sources are still coming in, nothing is dimmed and the verdict is
-- marked provisional -- which is the flag section 15b comes back for.
--
-- The tile ids ARE the service's source ids, so there is no mapping table.
local function CategoryHasEntries(results, id)
  local list = results[id]
  return (list and #list > 0) and true or false
end

function RefreshCategoryEmptiness(panel, results)
  if not panel or not panel.ContactButtons then return end

  local CS = Contacts()
  if type(CS) ~= "table" or type(CS.BuildSuggestions) ~= "function" then return end

  local ready = true
  if type(CS.SourcesReady) == "function" then
    local ok, answer = pcall(CS.SourcesReady)
    -- A service that cannot answer is treated as ready: the alternative is a
    -- bar that never dims at all.
    ready = (not ok) or (answer and true or false)
  end
  panel._catEmptyProvisional = not ready

  results = results or CS.BuildSuggestions("")

  for i = 1, #panel.ContactButtons do
    local b = panel.ContactButtons[i]
    local id = b._catId
    -- The star answers to its own favourite count (RefreshContactBar) and the
    -- All button is handled below, from every section rather than from one.
    if id and id ~= "all" and id ~= "favorites" then
      b._empty = ready and not CategoryHasEntries(results, id)
    end
  end

  local all = panel.AllButton
  if all then
    -- All is empty only when every section it would show is -- including the
    -- two that have no tile of their own (favourites, and hand-added
    -- recipients), because the unfiltered view still lists them.
    local any = false
    for i = 1, #PICKER_SECTIONS do
      if CategoryHasEntries(results, PICKER_SECTIONS[i].key) then
        any = true
        break
      end
    end
    all._empty = ready and not any
  end
end

-- Forward declaration: a row's click handler repopulates the list it is in.
local PopulateContactPicker

-- Row scripts are installed ONCE, at creation, and read the row's identity from
-- a field re-bound on each acquire. Installing them per populate is a closure
-- per row per refresh, and WoW cannot free either.
local function RowEnter(self)
  Theme.StyleMailRow(self, self._position or 0, true)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetText(self.address or "", 1, 1, 1)
  GameTooltip:AddLine(FavHintText(), 0.75, 0.75, 0.75, true)
  GameTooltip:AddLine(HideHintText(), 0.75, 0.75, 0.75, true)
  GameTooltip:Show()
end

local function RowLeave(self)
  Theme.StyleMailRow(self, self._position or 0, false)
  GameTooltip:Hide()
end

local function RowClick(self, button)
  local picker = self._picker
  local panel = picker and picker.panel
  local name = self.address
  if not panel or not name then return end

  if button == "RightButton" then
    local R = ns.Recipients
    if type(R) ~= "table" then return end
    if IsShiftKeyDown() then
      if type(R.SetHidden) == "function" then R.SetHidden(name, not R.IsHidden(name)) end
    elseif type(R.SetFavorite) == "function" then
      R.SetFavorite(name, not R.IsFavorite(name))
    end
    GameTooltip:Hide()
    -- Repopulate in place: the row the player just hid has to leave the list,
    -- and a new favourite has to appear in the favourites section.
    -- Unfavouriting the last one lands on the empty state, which says how to
    -- make another; closing the picker instead looked like the click had
    -- dismissed the window.
    PopulateContactPicker(picker)
    RefreshContactBar(panel)
    return
  end

  ST.SetRecipient(panel, name)
  picker:Hide()
end

-- ONE WIDGET PER VISIBLE ROW, not per name. `index` is a VIEWPORT slot, so the
-- pool is bounded by how many rows fit on screen (~14 at PICKER_MAX_H) rather
-- than by the size of the list. It used to be indexed by the row's position in
-- the whole list, which meant the first click on the All or Guild tile in a
-- 900-member guild permanently created ~900 Buttons, each with a FontString and
-- a Texture, none of which WoW can ever free.
--
-- Nothing about a row is skinned by a host UI -- neither skin's tree walk acts
-- on an untagged Button, deliberately, so that mail rows and picker rows keep
-- the addon's own striping -- so a recycled row's whole appearance comes from
-- BindPickerRow below, which runs on every bind rather than only at creation.
local function AcquireRow(picker, index)
  local row = picker.Rows[index]
  if row then return row, false end

  row = CreateFrame("Button", nil, picker.Child)
  row:SetHeight(ROW_H)
  row._picker = picker

  row.Text = Theme.CreateText(row, "bodySmall")
  row.Text:SetPoint("LEFT", row, "LEFT", ROW_INDENT, 0)
  row.Text:SetPoint("RIGHT", row, "RIGHT", -16, 0)
  row.Text:SetJustifyH("LEFT")
  row.Text:SetWordWrap(false)

  -- Favourite marker, so membership is legible from any category. Always the
  -- filled star: it is only ever shown on a row that IS a favourite.
  row.Star = row:CreateTexture(nil, "OVERLAY")
  row.Star:SetSize(11, 11)
  row.Star:SetPoint("RIGHT", row, "RIGHT", -3, 0)
  ApplyFavoriteIcon(row.Star, true)
  row.Star:Hide()

  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnEnter", RowEnter)
  row:SetScript("OnLeave", RowLeave)
  row:SetScript("OnClick", RowClick)

  picker.Rows[index] = row
  return row, true
end

-- Group headings. These used to be drawn with the row widget -- same indent,
-- same font, a faint background of their own -- which made them read as
-- clickable rows that happened not to respond. They are their own widget: a
-- plain Frame, so it cannot take a click even in principle; flush left where
-- names are indented; the brand gold where names are white; and a rule running
-- out to the right edge.
--
-- Pooled by viewport slot like the rows, for the same reason -- and because a
-- heading scrolled off the top must be free to become the next one scrolled in
-- at the bottom.
local function AcquireHeader(picker, index)
  local header = picker.Headers[index]
  if header then return header, false end

  header = CreateFrame("Frame", nil, picker.Child)
  header:SetHeight(HEADER_H)
  header:EnableMouse(false)

  header.Text = Theme.CreateText(header, "heading")
  header.Text:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 2, 2)
  header.Text:SetJustifyH("LEFT")
  header.Text:SetWordWrap(false)

  -- Anchored to the label's own right edge: the font string is unconstrained,
  -- so it sizes to the text and the rule always starts just after it, in any
  -- locale.
  header.Rule = header:CreateTexture(nil, "ARTWORK")
  header.Rule:SetHeight(1)
  header.Rule:SetPoint("LEFT", header.Text, "RIGHT", M.gap, 0)
  header.Rule:SetPoint("RIGHT", header, "RIGHT", -2, 0)
  Theme.FillColor(header.Rule, "accentRule")

  picker.Headers[index] = header
  return header, true
end

-- Everything a row shows, applied on every bind.
--
-- Deliberately not split into "set once at creation" and "set per refresh": a
-- recycled row carries the previous name's label, star and stripe until each is
-- overwritten, so anything that is not rewritten here is a stale artefact of
-- whoever occupied the slot last.
local function BindPickerRow(row, item)
  local name = item.address
  row.address = name
  row._position = item.position

  local R = ns.Recipients
  local stored = (type(R) == "table" and type(R.Get) == "function") and R.Get(name) or nil

  local label = DecorateAddress(name)
  -- The note is a picker-only affordance: the as-you-type rows are a single
  -- tight line and have no room for it.
  if stored and type(stored.note) == "string" and stored.note ~= "" then
    label = label .. "  " .. Theme.Colorize("textDisabled", stored.note)
  end
  row.Text:SetText(label)
  row.Star:SetShown(stored ~= nil and stored.fav == true)

  -- Painted from the row's DISPLAYED position through the same primitive the
  -- mail list uses, so the two lists stripe alike and the stripe stays put as
  -- the list scrolls under it.
  --
  -- A row rebound while the cursor is over it never gets an OnLeave and never
  -- gets a fresh OnEnter, so it would keep the previous name's highlight AND
  -- the previous name's tooltip. Re-running the enter handler settles both.
  if row:IsMouseOver() then
    RowEnter(row)
  else
    Theme.StyleMailRow(row, item.position, false)
  end
end

-- Materialises only the slice of the display list the viewport can show, and
-- re-binds it on every scroll tick.
--
-- The list is not uniform-height (headings are 17px, names 18, and a heading
-- carries HEADER_GAP of air above it), so the first visible item cannot be
-- derived by division the way the mail list's can. Each item carries its own
-- resolved `y` instead, and those are monotonically increasing, so the first
-- one is found by bisection -- O(log n) per scroll tick rather than O(n).
local function UpdatePickerRows(picker)
  local scroll = picker.Scroll
  -- Nothing to bind before EnsureContactPicker has finished wiring the frame up.
  if not (scroll and picker.Rows and picker._items) then return end

  local items = picker._items
  local count = picker._itemCount or 0

  -- A frame whose size comes only from its anchors reports 0 until the first
  -- layout pass, and the FIRST open must not be the one pass that materialises
  -- the entire list. Derive the viewport from the picker, and failing that from
  -- the picker's own ceiling: an over-estimate costs a few surplus rows, an
  -- unbounded one costs a frame per name.
  local viewport = scroll:GetHeight() or 0
  if viewport <= 1 then viewport = max((picker:GetHeight() or 0) - 2 * PICKER_PAD, 0) end
  if viewport <= 1 then viewport = PICKER_MAX_H end

  local offset = scroll:GetVerticalScroll() or 0

  -- The first item whose BOTTOM edge is still below the top of the viewport.
  local first, lo, hi = count + 1, 1, count
  while lo <= hi do
    local mid = floor((lo + hi) / 2)
    local item = items[mid]
    if item.y + (item.header and HEADER_H or ROW_H) > offset then
      first, hi = mid, mid - 1
    else
      lo = mid + 1
    end
  end

  local rowsUsed, headersUsed, created = 0, 0, false
  local limit = offset + viewport

  for index = first, count do
    local item = items[index]
    if item.y >= limit then break end

    local y = -item.y
    if item.header then
      headersUsed = headersUsed + 1
      local header, isNew = AcquireHeader(picker, headersUsed)
      created = created or isNew
      -- TOPLEFT + TOPRIGHT, never LEFT/RIGHT: two corner points on the same
      -- edge fix the width and the top without also constraining the vertical
      -- centre, which would fight SetHeight.
      header:ClearAllPoints()
      header:SetPoint("TOPLEFT", picker.Child, "TOPLEFT", 0, y)
      header:SetPoint("TOPRIGHT", picker.Child, "TOPRIGHT", 0, y)
      header.Text:SetText(item.title or "")
      header:Show()
    else
      rowsUsed = rowsUsed + 1
      local row, isNew = AcquireRow(picker, rowsUsed)
      created = created or isNew
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", picker.Child, "TOPLEFT", 0, y)
      row:SetPoint("TOPRIGHT", picker.Child, "TOPRIGHT", 0, y)
      -- Shown before it is bound, so BindPickerRow's IsMouseOver test is asked
      -- of a row that is actually on screen.
      row:Show()
      BindPickerRow(row, item)
    end
  end

  -- Surplus widgets are hidden, never destroyed or re-parented, and their
  -- identity is dropped with them so a click on a hidden row cannot address
  -- whoever used to be in that slot.
  for i = rowsUsed + 1, #picker.Rows do
    local row = picker.Rows[i]
    row.address = nil
    row:Hide()
  end
  for i = headersUsed + 1, #picker.Headers do
    picker.Headers[i]:Hide()
  end

  -- Widgets built on this pass have never been through the skin. Neither skin
  -- currently acts on an untagged Button or a bare Frame, so this is insurance
  -- rather than a requirement -- but it is what the other two lists do, and a
  -- row that first appears three scroll ticks in must not be the one the skins
  -- never saw.
  if created and ns.Skin and ns.Skin.Refresh then
    pcall(ns.Skin.Refresh, picker:GetParent())
  end
end

local function EnsureContactPicker(panel)
  if panel.ContactPicker then return panel.ContactPicker end

  local f = CreateFrame("Frame", nil, panel, "BackdropTemplate")
  f:SetSize(PICKER_MIN_W, PICKER_MAX_H)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)

  -- The one card surface. Its own near-black fill was close, but its neutral
  -- grey border was the only grey border in the addon and it sat next to the
  -- type-ahead popup, which was warm. ApplyCard also sets __postboxPanel, so
  -- the tag can no longer be set here without the surface or the other way
  -- round -- which is exactly how the two skins came to disagree about which
  -- frames they skinned.
  Theme.ApplyCard(f)
  f:Hide()

  f.panel = panel
  -- Which category the list is narrowed to; the bar sets it before opening us.
  f.Filter = "all"

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", f, "TOPLEFT", PICKER_PAD, -PICKER_PAD)
  -- One gutter width for every scroll frame in the addon, wide enough that the
  -- classic bar clears the container's border art.
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -M.scrollGutter, PICKER_PAD)

  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(PICKER_MIN_W - M.scrollGutter - PICKER_PAD, 10)
  scroll:SetScrollChild(child)

  -- Two pools, deliberately: a heading is never a recycled row, so it can never
  -- inherit a row's click handler or lose its own styling to one. Both are
  -- indexed by VIEWPORT SLOT -- see AcquireRow -- and `_items` is the flat
  -- display list they are bound from.
  --
  -- Filled in BEFORE the scroll hooks below: those call UpdatePickerRows, which
  -- reads every one of them.
  f.Scroll, f.Child, f.Rows, f.Headers = scroll, child, {}, {}
  f._items, f._itemCount = {}, 0

  -- HookScript, not SetScript: UIPanelScrollFrameTemplate installs its own
  -- handlers on both of these and replacing them desynchronises the scroll bar
  -- from the frame it scrolls. (OnSizeChanged was a SetScript here, which is
  -- how the picker's bar could disagree with its own content.)
  scroll:HookScript("OnSizeChanged", function(_, w)
    if w and w > 10 then child:SetWidth(w) end
    UpdatePickerRows(f)
  end)
  scroll:HookScript("OnVerticalScroll", function() UpdatePickerRows(f) end)

  -- What the picker says when the category it was opened on holds nothing.
  -- Favourites is the one everybody meets empty on day one: the star opens the
  -- list rather than refusing to, and this is where "you have none yet" gets
  -- explained along with how to leave that state.
  f.Empty = Theme.CreateText(child, "secondary")
  f.Empty:SetPoint("TOPLEFT", child, "TOPLEFT", ROW_INDENT - M.gap, -M.inset)
  f.Empty:SetPoint("TOPRIGHT", child, "TOPRIGHT", -M.gap, -M.inset)
  f.Empty:SetJustifyH("LEFT")
  f.Empty:SetJustifyV("TOP")
  f.Empty:SetWordWrap(true)
  f.Empty:Hide()

  -- Whatever closes the picker (a pick, the toggle, a Hide from elsewhere) also
  -- has to clear the bar's active highlight.
  f:SetScript("OnHide", function()
    -- Only our own row tooltip, never whatever else happens to be showing --
    -- the star button's, when its click is what closed us.
    local owner = GameTooltip.GetOwner and GameTooltip:GetOwner()
    if owner and owner.GetParent and owner:GetParent() == child then
      GameTooltip:Hide()
    end
    RefreshContactBar(panel)
  end)

  panel.ContactPicker = f
  return f
end

-- Empty-state copy, per category.
--
-- "Nothing in this list yet." is true and useless in the two cases players
-- actually meet: not being in a guild, and clicking Guild inside the roster
-- round trip on a cold login. Only ContactService knows which of those it is --
-- it is the only module that knows whether a request is still outstanding -- so
-- it decides, and returns a LOCALE KEY rather than a sentence so every string
-- stays in Core/Locales.lua. The recipient manager asks the same function, so
-- the two windows cannot explain the same empty list differently.
--
-- The picker's filter ids are already the service's source ids ("guild",
-- "friends", "alts", "recent"), so there is no mapping table. `all` and
-- `favorites` fall through: favourites is the one the user is sent to by a
-- button rather than by choosing a category, so it is the one that has to
-- teach, and it has copy of its own.
local function EmptyPickerText(filter)
  if filter == "favorites" then return L["CONTACT_EMPTY_FAVORITES"] end

  local CS = Contacts()
  if type(CS) == "table" and type(CS.EmptyReason) == "function" then
    local ok, key = pcall(CS.EmptyReason, filter)
    if ok and type(key) == "string" and key ~= "" then return L[key] end
  end
  return L["CONTACT_EMPTY_CATEGORY"]
end

-- Which sections the current filter puts on screen.
--
-- A tile shows exactly its own source now. The Recent tile used to also open
-- the recent-allies bucket, which is how "Recent" came to mean two things at
-- once and how a group with no tile of its own got on screen.
--
-- The wrapper tables are reused across populates rather than rebuilt: six
-- tables per open is not much, but this runs again on every right-click
-- favourite toggle.
local visibleSections = {}

local function CollectSections(results, filter)
  local count = 0
  for i = 1, #PICKER_SECTIONS do
    local section = PICKER_SECTIONS[i]
    local entries = (filter == "all" or filter == section.key) and results[section.key] or nil
    if entries and #entries > 0 then
      count = count + 1
      local slot = visibleSections[count]
      if not slot then slot = {}; visibleSections[count] = slot end
      slot.section, slot.entries = section, entries
    end
  end
  for i = #visibleSections, count + 1, -1 do visibleSections[i] = nil end
  return visibleSections
end

-- Builds the flat DISPLAY LIST -- every heading and every name, each with its
-- resolved y -- and hands it to UpdatePickerRows, which materialises only the
-- part of it the viewport can show.
--
-- Splitting the two is what bounds the widget count by the viewport rather than
-- by the roster. It also moves the per-name string work (R.Get, DecorateAddress,
-- Theme.Colorize) out of here and into the bind, so a 900-name list costs 900
-- table entries instead of 900 frames and 2,700 strings.
function PopulateContactPicker(picker)
  local panel = picker.panel
  if not panel then return end

  local filter = picker.Filter or "all"

  -- No opts: hidden recipients stay out of every list this screen draws, this
  -- one and the type-ahead alike. The recipient manager is the only caller that
  -- asks for them, because it is the window you go to in order to unhide.
  local results = Contacts().BuildSuggestions("")
  -- The snapshot the bar's dimming needs, while it is in hand and free. Every
  -- route that changes what a category holds -- a favourite toggled, a hidden
  -- recipient restored, a roster arriving -- comes back through here.
  RefreshCategoryEmptiness(panel, results)
  local sections = CollectSections(results, filter)

  -- Headings are only drawn when more than one section is on screen. A filtered
  -- view -- or an unfiltered one that happens to hold a single group -- is one
  -- list, and one list does not need a label saying so.
  local withHeadings = #sections > 1

  local items = picker._items
  local count, rowCount, y = 0, 0, 0

  -- Item tables are reused in place across populates, so a favourite toggle on
  -- a large roster reallocates nothing.
  local function PushItem()
    count = count + 1
    local item = items[count]
    if not item then item = {}; items[count] = item end
    item.y = y
    return item
  end

  for i = 1, #sections do
    local section = sections[i].section
    local entries = sections[i].entries

    if withHeadings then
      -- Air above every group but the first, so a heading belongs to the names
      -- below it rather than sitting in the middle of the list.
      if y > 0 then y = y + HEADER_GAP end
      local item = PushItem()
      item.header, item.title = true, L[section.titleKey]
      item.address, item.position = nil, nil
      y = y + HEADER_H
    end

    -- The `recent` list arrives most-recent-first and that order is the entire
    -- reason the category exists, so it is NOT passed through SortForDisplay --
    -- which would alphabetise it and put the person you wrote to ten minutes
    -- ago thirtieth. Note the sorted branch returns the shared scratch array
    -- and the unsorted one returns the service's own; neither is written to.
    local ordered = section.ordered and entries or SortForDisplay(entries)

    -- The cap belongs to the ALL view alone. There Recent is a shortcut to the
    -- top of the mail history sitting above the full lists; clicking the Recent
    -- tile is a request for the whole thing.
    local limit = #ordered
    if filter == "all" and section.max and section.max < limit then limit = section.max end

    for j = 1, limit do
      rowCount = rowCount + 1
      local item = PushItem()
      item.header, item.title = nil, nil
      item.address, item.position = ordered[j], rowCount
      y = y + ROW_H
    end
  end

  for i = #items, count + 1, -1 do items[i] = nil end
  picker._itemCount = count

  if rowCount == 0 then
    picker.Empty:SetText(EmptyPickerText(filter))
    picker.Empty:Show()
    -- Measured rather than fixed: the German string runs a line longer than the
    -- English one, and a fixed height would cut it off inside a scroll frame
    -- with nothing to scroll to.
    y = max(ceil(picker.Empty:GetStringHeight() or 0) + 2 * M.inset, 48)
  else
    picker.Empty:Hide()
  end

  local content = max(y, 10)
  picker.Child:SetHeight(content)
  picker._contentHeight = y + 2 * PICKER_PAD

  -- A favourite toggle can shorten the list under a scroll offset that was
  -- valid a moment ago. The scroll frame keeps that offset, the bind then finds
  -- no items past it, and the viewport goes blank over a list that has content.
  -- Clamp before anything reads the offset.
  local scroll = picker.Scroll
  if scroll then
    local maxScroll = max(0, content - (scroll:GetHeight() or 0))
    if (scroll:GetVerticalScroll() or 0) > maxScroll then scroll:SetVerticalScroll(maxScroll) end
    if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
  end

  UpdatePickerRows(picker)
end

-- Places the picker below the bar, or above it when there is more room there,
-- and clamps its height to the room actually available. It could previously be
-- 320px tall anchored ~70px down a ~330px panel and simply hung off the bottom
-- of the window.
local function PlacePicker(panel, picker)
  local bar = panel.ContactBar
  local desired = min(max(picker._contentHeight or PICKER_MIN_H, PICKER_MIN_H), PICKER_MAX_H)

  -- The picker belongs to the window, so the window's edges are the limit; the
  -- screen is the fallback when the window cannot be measured.
  local frame = ns.MailboxUI and ns.MailboxUI._frame
  local floorY = frame and frame.GetBottom and frame:GetBottom() or nil
  local ceilY  = frame and frame.GetTop and frame:GetTop() or nil
  if type(floorY) ~= "number" then floorY = 0 end
  if type(ceilY) ~= "number" then
    ceilY = (UIParent and UIParent.GetTop and UIParent:GetTop()) or 768
  end

  local anchorBottom = bar.GetBottom and bar:GetBottom() or nil
  local anchorTop    = bar.GetTop and bar:GetTop() or nil

  local above = false
  local room = desired
  if type(anchorBottom) == "number" and type(anchorTop) == "number" then
    local below = anchorBottom - PICKER_GAP - (floorY + PICKER_EDGE_PAD)
    local over  = (ceilY - PICKER_EDGE_PAD) - (anchorTop + PICKER_GAP)
    if below < desired and over > below then
      above, room = true, over
    else
      room = below
    end
  end

  -- A window too short to hold even the minimum gets the minimum: a list 40px
  -- tall is unusable, and at that point a few pixels of overhang is the lesser
  -- fault. Everything above that clamps exactly.
  picker:SetHeight(max(min(desired, room), PICKER_MIN_H))
  picker:SetWidth(max(ResolvedWidth(bar, panel, M.inset), PICKER_MIN_W))

  picker:ClearAllPoints()
  if above then
    picker:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, PICKER_GAP)
  else
    picker:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -PICKER_GAP)
  end
end

local function OpenContactMenu(panel, filter)
  local picker = EnsureContactPicker(panel)

  -- Clicking the category you are already showing closes the picker; clicking a
  -- different one switches to it without a second click.
  if picker:IsShown() and (not filter or picker.Filter == filter) then
    picker:Hide()
    return
  end

  if filter then picker.Filter = filter end
  CloseOtherLists(panel, picker)

  -- A list opened from the bar starts at the top: switching from a guild you
  -- were 400px into, to Alts, must not land halfway down a list of four. Only
  -- an IN-PLACE repopulate keeps the offset -- the right-click favourite toggle
  -- calls PopulateContactPicker directly and never comes through here, which is
  -- what keeps the row the player just clicked under their cursor.
  if picker.Scroll then picker.Scroll:SetVerticalScroll(0) end

  PopulateContactPicker(picker)
  PlacePicker(panel, picker)
  picker:Show()
  picker:Raise()
  RefreshContactBar(panel)

  -- The picker's PARENT, not the picker: both skins walk the children of what
  -- they are given, so passing the picker itself would skin its rows and leave
  -- its own card surface unstyled until the window was next re-shown.
  if ns.Skin and ns.Skin.Refresh then ns.Skin.Refresh(picker:GetParent()) end
end

-------------------------------------------------------------
-- 15. The type-ahead popup
--
-- Appears under the recipient field as the player types. Same card surface as
-- the picker: the two can appear within a second of each other under the same
-- field and must look identical.
-------------------------------------------------------------

local SUGGEST_ROW_H  = ROW_H
local SUGGEST_PAD    = 2
-- The player is still typing. Querying every source on every keystroke walked a
-- guild roster of hundreds per character; one pass 150ms after they stop is
-- indistinguishable to them and a fraction of the work.
local SUGGEST_DEBOUNCE = 0.15
-- Long enough that a click on a suggestion lands before the popup goes away.
local SUGGEST_GRACE = 0.15

-- Favourites lead: they are stored state, so a favourite who has left the guild
-- (and is in no live source any more) is still completable. Then the live
-- sources, most-likely first.
--
--   `recent` before `alts` because a type-ahead should lead with who the player
--   actually writes to.
--   `grouped` -- people recently grouped with -- is here even though it gets no
--   section in the picker: a half-remembered name from last night's dungeon is
--   exactly what a type-ahead is for, which is not the same as a list anybody
--   browses.
--   `manual` and `other` last, in that order: a hand-added recipient is at
--   least something the player entered themselves, whereas `other` is whatever
--   the client's own autocomplete offered that no source claimed -- the least
--   confident answer in the set.
--
-- Membership across these lists is no longer exclusive (the same guildmate can
-- be in `recent`, `guild` AND `friends`), which is what makes each category
-- true to its name. The lowercase dedup below is what collapses the repeats,
-- and this flat list is the one place a single answer per person is wanted.
local SUGGEST_ORDER = {
  "favorites", "recent", "alts", "guild", "friends", "grouped", "manual", "other",
}

-- HIDDEN MEANS HIDDEN. No opts, exactly like the picker above: a recipient the
-- player has hidden is absent from this list, not present-but-dimmed. Hiding
-- used to remove a name from the browsable lists only, on the reasoning that
-- somebody typing the name themselves should still be completed -- which meant
-- the gesture the tooltip advertised appeared to do nothing at all in the one
-- list it was performed in. The field is free text, so a hidden name can still
-- be typed out in full; the recipient manager's Hidden filter is the way back.

local suggestFlat, suggestSeen = {}, {}

-------------------------------------------------------------
-- 15a. The To: box completes itself, and Tab walks the popup
--
-- Two things happen under the To: box, and they are kept distinct on purpose:
--
--   INLINE COMPLETION. Type "ars", the box reads "Arsol" with "ol" SELECTED,
--   so carrying on typing simply replaces it and the completion never has to
--   be dismissed. It is the popup's first row that can be reached by
--   EXTENDING what was typed; a row that matched by substring is never
--   completed to, because that would rewrite the player's own characters.
--
--   TAB. Every press puts the next popup row into the box, top to bottom in
--   the popup's own order -- substring matches included -- and Shift+Tab
--   walks back up; both wrap. The first press takes the row the inline
--   completion is already showing, if there is one, and row one otherwise;
--   there is no separate "accept" press, because the box holding the name IS
--   acceptance. A row Tab has taken is a whole address, cursor at the end,
--   nothing selected: typing after it appends, Escape puts the typed text
--   back. The popup stays open with a marker on the row being held, so the
--   player can see what Tab took and what the next press will take.
--
--   Tab used to walk a different list from the one on screen -- the
--   completable rows only -- which is why it appeared to skip: with "sh"
--   typed and Shameo, How-Crushridge, Khrash, Shaanked showing, the second
--   press went to Shaanked. And the first press was an accept with no
--   visible effect when the completion was already on screen, so sometimes
--   Tab moved one row and sometimes none. One list, one rule, now.
--
-- Three rules keep the inline half from fighting the player, and every one of
-- them is a rule because breaking it is what makes this pattern hated:
--
--   IT ONLY EVER EXTENDS. The completion is `typed .. remainder` -- the
--   player's own characters, byte for byte, with their own casing, plus the
--   tail of the suggestion.
--
--   IT ONLY FIRES ON AN INSERTION AT THE END. Never on a deletion, never on an
--   edit in the middle, never on a paste. Backspace that re-completed the
--   character just removed would make the field impossible to shorten, and a
--   completion appended while the cursor is in the middle of the text is simply
--   somebody else typing. `AppendedOneChar` plus a cursor-at-the-end test is the
--   whole of that decision.
--
--   IT USES THE POPUP'S OWN RANKING. There is exactly one ordered list of
--   suggestions on this screen (`suggestFlat`), and both halves read it rather
--   than scoring anything themselves, so the popup, the completion and Tab
--   can never disagree about who the best answer is.
--
-- MATCHING is CS.Fold, the same fold the lists sort by. It maps characters one
-- to one -- an accented letter to its base, a Cyrillic letter to its capital
-- -- and does NOT preserve byte length, so the splice counts CHARACTERS on the
-- raw name: fold(name) starting with fold(typed) means the first N characters
-- of name are what was typed, and the remainder starts after those N.
-------------------------------------------------------------

-- Panel state, all of it:
--
--   _acTyped   what the player actually typed (never includes completed text)
--   _acPrev    the box's text as of the last time this code looked at it
--   _acFull    the text this code last wrote into the box, or nil
--   _acName    the popup row _acFull stands for
--   _acList    the popup's rows in its order (suggestFlat itself), or nil
--   _acIndex   where _acName sits in _acList, or nil once it is no longer there
--   _acTaken   Tab has taken a row: a whole address, nothing selected
--   _acArmed   the last edit was an insertion at the end (see NoteRecipientEdit)
--   _acGuard   set around our own SetText, so it cannot read as a player edit

-- Forward: defined after CompletionShowing, called from the offer paths above it.
local PaintTabMarker

-- True when `text` is `base` with exactly ONE more character on the end.
--
-- Characters, not bytes: an accented or Cyrillic letter is two bytes and typing
-- one must still complete. Counting bytes would have made this feature work in
-- enUS and quietly not at all in frFR and ruRU. The same test is what rejects a
-- PASTE -- two characters arriving at once are not a keystroke.
local function AppendedOneChar(base, text)
  local n = #base
  if #text <= n then return false end
  if text:sub(1, n) ~= base then return false end

  local lead = string.byte(text, n + 1)
  -- A continuation byte where a character should start: the text grew, but not
  -- by a whole character.
  if lead >= 128 and lead < 192 then return false end
  for i = n + 2, #text do
    local b = string.byte(text, i)
    -- Anything that is not a continuation byte begins a SECOND character.
    if b < 128 or b >= 192 then return false end
  end
  return true
end

-- The first popup row that can be reached by EXTENDING `typed`, and the text
-- that extension puts in the box. nil when no row extends what was typed.
local function FirstInlineCompletion(typed)
  if typed == "" then return nil end
  local CS = Contacts()
  if type(CS) ~= "table" or type(CS.Fold) ~= "function" then return nil end
  local H = Helpers()

  local folded = CS.Fold(typed)
  local count = H.CharCount(typed)
  for i = 1, #suggestFlat do
    local name = suggestFlat[i]
    if CS.Fold(name):sub(1, #folded) == folded then
      -- STRICTLY longer: a row that IS what was typed cannot be extended, and
      -- "completing" it would select an empty range.
      local at = H.CharBoundary(name, count)
      if at and at <= #name then
        return i, typed .. name:sub(at)
      end
    end
  end
  return nil
end

-- The box holds text this code wrote. Everything that overwrites the box from
-- code goes through here so the next keystroke is measured against it.
function ResetInlineCompletion(panel, text)
  if not panel then return end
  local value = text or ""
  panel._acTyped, panel._acPrev = value, value
  panel._acFull, panel._acName = nil, nil
  panel._acList, panel._acIndex = nil, nil
  panel._acTaken, panel._acArmed = nil, nil
end

-- Nothing to complete to. The text on screen is left exactly as it is -- this
-- says the OFFER has lapsed, not that the box is wrong.
local function ClearCompletionOffer(panel)
  panel._acList, panel._acIndex, panel._acName = nil, nil, nil
  panel._acTaken, panel._acArmed = nil, nil
  PaintTabMarker(panel)
end

-- Is the text this code last wrote still what is on screen?
local function CompletionShowing(panel)
  local full = panel._acFull
  return full ~= nil and panel.ToBox:GetText() == full
end

-- Put `full` -- the typed text plus the tail of row `index` -- in the box with
-- everything past the typed prefix selected.
--
-- The guard is what stops this reading as a player edit. OnTextChanged is told
-- `userInput = false` for a programmatic SetText and the handler already leans
-- on that, so this is the second lock on the same door -- and the one that holds
-- if a host UI ever calls the handler itself.
local function ShowInline(panel, index, full)
  local box = panel.ToBox
  local typedLen = #(panel._acTyped or "")

  panel._acGuard = true
  box:SetText(full)
  -- SetText leaves the cursor at the end, which is where it belongs: the
  -- selection runs from the last character the player typed to it, so the next
  -- keystroke overwrites the completion instead of appending to it.
  box:HighlightText(typedLen, #full)
  panel._acGuard = false

  panel._acFull, panel._acPrev = full, full
  panel._acIndex, panel._acName = index, panel._acList[index]
  panel._acTaken = nil
  PaintTabMarker(panel)
end

-- Put row `index` in the box whole: the same address a click on the row would
-- insert, cursor at the end, nothing selected. `_acTyped` is left alone, so
-- Escape still knows what to put back and the popup still knows what it is
-- answering.
local function TakeRow(panel, index)
  local box = panel.ToBox
  local name = panel._acList[index]
  local value = name
  local R = ns.Recipients
  if type(R) == "table" and type(R.Display) == "function" then
    local resolved = R.Display(name)
    if resolved ~= "" then value = resolved end
  end

  panel._acGuard = true
  box:SetText(value)
  box:HighlightText(0, 0)
  box:SetCursorPosition(#value)
  panel._acGuard = false

  panel._acFull, panel._acPrev = value, value
  panel._acIndex, panel._acName = index, name
  panel._acTaken = true
  PaintTabMarker(panel)
end

-- Paints "this is the row Tab is holding" onto the popup: a live-accent bar
-- and a faint wash on the source row of the text in the box, so the player
-- can see what Tab took and what the next Tab would step to. Repainted from
-- every path that changes what is held AND from the popup fill, so the marker
-- can never describe a row that is gone. The art lives on the row buttons,
-- which are not tagged panels, so a host skin's repaint does not fade it.
PaintTabMarker = function(panel)
  local sf = panel.SuggestFrame
  if not sf or not sf.buttons then return end
  local current = CompletionShowing(panel) and panel._acName or nil
  for i = 1, #sf.buttons do
    local btn = sf.buttons[i]
    local on = current ~= nil and btn.value == current and btn:IsShown()
    if on and not btn.TabMarkBar then
      local wash = btn:CreateTexture(nil, "BACKGROUND")
      wash:SetAllPoints()
      btn.TabMarkWash = wash
      local bar = btn:CreateTexture(nil, "ARTWORK")
      bar:SetWidth(2)
      bar:SetPoint("TOPLEFT", btn, "TOPLEFT", -SUGGEST_PAD + 2, 0)
      bar:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", -SUGGEST_PAD + 2, 0)
      btn.TabMarkBar = bar
    end
    if btn.TabMarkBar then
      if on then
        -- The live accent, resolved at paint time: under a host skin the
        -- user's own colour is the accent.
        local r, g, b = Theme.GetAccent()
        btn.TabMarkWash:SetColorTexture(r, g, b, 0.10)
        btn.TabMarkBar:SetColorTexture(r, g, b, 0.9)
      end
      btn.TabMarkWash:SetShown(on)
      btn.TabMarkBar:SetShown(on)
    end
  end
end

-- Binds the offer to the list the popup is showing, and applies the inline
-- completion when the last edit was an insertion at the end. Called at the
-- tail of every suggestion pass, so the popup and the completion are always
-- the same answer.
local function UpdateInlineCompletion(panel)
  local typed = panel._acTyped or ""
  local armed = panel._acArmed
  panel._acArmed = nil

  if #suggestFlat == 0 or typed == "" then
    panel._acList, panel._acIndex, panel._acName, panel._acTaken = nil, nil, nil, nil
    PaintTabMarker(panel)
    return
  end
  panel._acList = suggestFlat

  -- A pass rebuilt the popup UNDER text this code wrote -- a roster tick
  -- refreshing the open popup (ContactsChanged), or the debounce landing
  -- between two Tab presses. The Tab conversation in progress survives:
  -- re-find the held row's place in the new list and keep the taken state.
  -- Wiping it here is what once made the second Tab press a visible no-op.
  -- A held row that is no longer listed leaves the index nil, and the next
  -- Tab starts again from the top.
  if CompletionShowing(panel) then
    panel._acIndex = nil
    local name = panel._acName
    for i = 1, #suggestFlat do
      if suggestFlat[i] == name then panel._acIndex = i break end
    end
    PaintTabMarker(panel)
    return
  end

  panel._acIndex, panel._acName, panel._acTaken = nil, nil, nil

  -- The player deleted, pasted, or edited the middle. The offer stands -- Tab
  -- will take it -- but nothing appears in the box uninvited.
  if not armed then
    PaintTabMarker(panel)
    return
  end
  -- A keystroke landed between the pass being scheduled and it running. The
  -- debounce token normally catches that; this catches the paths that do not go
  -- through the debounce at all.
  if panel.ToBox:GetText() ~= typed then
    PaintTabMarker(panel)
    return
  end

  local index, full = FirstInlineCompletion(typed)
  if index then
    ShowInline(panel, index, full)
  else
    PaintTabMarker(panel)
  end
end

-------------------------------------------------------------
-- 15, continued: filling the popup in
-------------------------------------------------------------

local function RefreshSuggestions(panel)
  local sf = panel.SuggestFrame
  if not sf then return end

  local box = panel.ToBox
  local raw = box:GetText()
  -- THE QUERY IS WHAT THE PLAYER TYPED, not what the box currently reads. With a
  -- completion on screen those differ, and querying the completed text would
  -- collapse the popup to the single name we had just completed to -- taking the
  -- alternatives away at the exact moment the player is looking at them to
  -- decide. Every entry point re-derives it here, so the state stays honest
  -- however the box was last written to.
  local typed = (panel._acFull ~= nil and panel._acFull == raw) and panel._acTyped or raw
  panel._acTyped, panel._acPrev = typed, raw

  local H = Helpers()
  local text = H.NormalizeText(typed)
  if text == "" then
    ClearCompletionOffer(panel)
    sf:Hide()
    return
  end

  -- No opts: hidden means hidden here too. See the note above SUGGEST_ORDER.
  local results = Contacts().BuildSuggestions(text)

  for i = #suggestFlat, 1, -1 do suggestFlat[i] = nil end
  for key in pairs(suggestSeen) do suggestSeen[key] = nil end

  -- Lowercasing is enough to dedup, but only because every bucket holds a
  -- canonical address built by the same rule -- the buckets that deliberately
  -- repeat a recipient (favourites, alts) hand back the identical string, so
  -- the only thing left to reconcile is casing. The foundation's fold, not
  -- string.lower: see Lib/Util.lua.
  local lower = H.Lower
  for i = 1, #SUGGEST_ORDER do
    local bucket = results[SUGGEST_ORDER[i]]
    if bucket then
      for j = 1, #bucket do
        local name = bucket[j]
        local key = lower(name)
        if not suggestSeen[key] then
          suggestSeen[key] = true
          suggestFlat[#suggestFlat + 1] = name
        end
        if #suggestFlat >= MAX_SUGGESTIONS then break end
      end
    end
    if #suggestFlat >= MAX_SUGGESTIONS then break end
  end

  if #suggestFlat == 0 then
    ClearCompletionOffer(panel)
    sf:Hide()
    return
  end

  -- Resolved once, not per row: at most eight rows, but this runs on every
  -- debounced keystroke.
  local R = ns.Recipients
  local GetRow = (type(R) == "table" and type(R.Get) == "function") and R.Get or nil

  for i = 1, MAX_SUGGESTIONS do
    local btn = sf.buttons[i]
    local name = suggestFlat[i]
    if name then
      btn.label:SetText(DecorateAddress(name))
      btn.value = name

      -- The star, exactly as the picker's rows carry it: these are the same
      -- names under the same field and the two lists appear within a second of
      -- each other. There is no longer a dim state to go with it -- a hidden
      -- recipient is not in this list at all, so a row that is here is a row
      -- with nothing to say beyond whether it is a favourite.
      local stored = GetRow and GetRow(name) or nil
      btn.Star:SetShown(stored ~= nil and stored.fav == true)

      btn:Show()
    else
      btn.value = nil
      btn:Hide()
    end
  end

  sf:SetHeight(2 * SUGGEST_PAD + #suggestFlat * SUGGEST_ROW_H)
  -- Two lists this addon owns must never overlap.
  CloseOtherLists(panel, sf)
  sf:Show()
  sf:Raise()

  -- Last, and from the list that is now on screen: the completion IS the popup's
  -- first completable row, so it is decided from the same pass that drew it.
  UpdateInlineCompletion(panel)
end

local function ScheduleSuggestions(panel)
  local token = (panel._suggestToken or 0) + 1
  panel._suggestToken = token
  C_Timer.After(SUGGEST_DEBOUNCE, function()
    -- A later keystroke has already superseded this pass.
    if panel._suggestToken ~= token then return end
    RefreshSuggestions(panel)
  end)
end

-------------------------------------------------------------
-- 15a, continued: what the keyboard does
-------------------------------------------------------------

-- Every genuine edit to the To: box, recorded before the suggestion pass that
-- will act on it. This is the ONE place that decides whether the edit was an
-- insertion at the end -- the pass itself only reads the answer.
local function NoteRecipientEdit(panel, box)
  local text = box:GetText()
  local prev  = panel._acPrev or ""
  local typed = panel._acTyped or ""

  -- Measured against BOTH readings of "before", because both are edits that
  -- extend: typing over a live completion's selection grows what was TYPED
  -- ("ars" -> "arso"), while typing after a taken row grows what is in the
  -- BOX ("Arsol" -> "Arsolb"). One test alone gets the other case wrong.
  local grew = AppendedOneChar(typed, text) or AppendedOneChar(prev, text)

  -- ...and only with the cursor at the very end. "Bo|b" plus a "b" reads as an
  -- append when compared as strings and is nothing of the kind.
  panel._acArmed = grew and box:GetCursorPosition() == #text

  -- Whatever is in the box is now the player's own text, and any completion that
  -- was on screen has just been typed through.
  panel._acTyped, panel._acPrev = text, text
  panel._acFull, panel._acName = nil, nil
  panel._acList, panel._acIndex, panel._acTaken = nil, nil, nil
end

-- Tab, and Shift+Tab for the other direction. See the section header for the
-- rule; this is only its arithmetic.
--
-- Tab with no offer built yet is an explicit "complete it now", so the
-- debounced pass is run on the spot rather than making them wait it out or
-- press twice; the token is bumped so the pass already in flight does not then
-- run again and reset the walk.
local function RecipientTabPressed(panel)
  if not panel._acList then
    panel._suggestToken = (panel._suggestToken or 0) + 1
    RefreshSuggestions(panel)
  end

  local list = panel._acList
  if not list or #list == 0 then return end

  local backwards = IsShiftKeyDown()
  local index
  if CompletionShowing(panel) and panel._acIndex then
    if panel._acTaken then
      index = panel._acIndex + (backwards and -1 or 1)
      if index < 1 then index = #list elseif index > #list then index = 1 end
    else
      -- The inline completion is a row the popup already points at: the first
      -- press takes THAT row, whichever it is, rather than jumping past it.
      index = panel._acIndex
    end
  else
    index = backwards and #list or 1
  end
  TakeRow(panel, index)
end

-- Escape, first stage: put back exactly what was typed and close the popup,
-- WITHOUT giving up focus -- the player is cancelling a suggestion, not the
-- field. Returns false when there is nothing of ours to cancel, and the box's
-- own Escape (ClearFocus, from PrepareEditBox) stands.
local function RecipientEscapePressed(panel)
  if not CompletionShowing(panel) then return false end

  local box = panel.ToBox
  local typed = panel._acTyped or ""
  panel._acGuard = true
  box:SetText(typed)
  box:SetCursorPosition(#typed)
  panel._acGuard = false

  panel._acFull, panel._acPrev = nil, typed
  ClearCompletionOffer(panel)

  -- Cancel the debounced pass as well, or the popup reopens 150ms after being
  -- dismissed -- the same reasoning as CloseListsForResize.
  panel._suggestToken = (panel._suggestToken or 0) + 1
  if panel.SuggestFrame then panel.SuggestFrame:Hide() end
  return true
end

-- The type-ahead's rows answer to exactly the gestures the picker's rows do,
-- and say so in exactly the same words.
--
-- They used to be plain left-click buttons with no OnEnter at all: two visually
-- identical lists under the same field, one of which favourites on right-click
-- and teaches you how, the other silently ignoring the gesture it had just
-- taught. Right-click means favourite everywhere in the addon now -- the
-- recipient manager moved to match, and its note editing is a button on the row
-- instead.
local function SuggestionEnter(self)
  if not self.value then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetText(self.value, 1, 1, 1)
  GameTooltip:AddLine(FavHintText(), 0.75, 0.75, 0.75, true)
  GameTooltip:AddLine(HideHintText(), 0.75, 0.75, 0.75, true)
  GameTooltip:Show()
end

local function SuggestionLeave()
  GameTooltip:Hide()
end

local function SuggestionClick(self, button)
  local panel = self._panel
  local name = self.value
  if not panel or not name then return end

  if button == "RightButton" then
    local R = ns.Recipients
    if type(R) ~= "table" then return end
    if IsShiftKeyDown() then
      if type(R.SetHidden) == "function" then R.SetHidden(name, not R.IsHidden(name)) end
    elseif type(R.SetFavorite) == "function" then
      R.SetFavorite(name, not R.IsFavorite(name))
    end
    GameTooltip:Hide()
    -- Rebuilt in place, like the picker: favourites lead this list, so the name
    -- moves, and the bar's star count has to follow. The popup stays open and
    -- the To: box keeps its focus and its text -- nothing here touches the edit
    -- box, which is the whole reason a curation gesture can live in a list that
    -- appears while somebody is typing.
    RefreshSuggestions(panel)
    RefreshContactBar(panel)
    return
  end

  ST.SetRecipient(panel, name)
  -- The pick is not a keystroke: cancel any debounced pass so the popup cannot
  -- reopen itself a moment after it was chosen from.
  panel._suggestToken = (panel._suggestToken or 0) + 1
  panel.SuggestFrame:Hide()
end

local function CreateSuggestionPopup(panel)
  local sf = CreateFrame("Frame", nil, panel, "BackdropTemplate")
  sf:SetPoint("TOPLEFT", panel.ToWrap, "BOTTOMLEFT", 0, -1)
  sf:SetPoint("RIGHT", panel.ToWrap, "RIGHT", 0, 0)
  sf:SetHeight(10)
  sf:SetFrameStrata("FULLSCREEN_DIALOG")
  sf:SetToplevel(true)
  sf:SetClampedToScreen(true)

  -- The one card surface, and the __postboxPanel tag that comes with it. Until
  -- this call carried the tag, ElvUI skinned this popup and EllesmereUI did not.
  Theme.ApplyCard(sf)
  sf:Hide()

  sf.buttons = {}
  for i = 1, MAX_SUGGESTIONS do
    local btn = CreateFrame("Button", nil, sf)
    btn:SetHeight(SUGGEST_ROW_H)
    btn:SetPoint("TOPLEFT", sf, "TOPLEFT", SUGGEST_PAD, -SUGGEST_PAD - (i - 1) * SUGGEST_ROW_H)
    btn:SetPoint("RIGHT", sf, "RIGHT", -SUGGEST_PAD, 0)
    btn._panel = panel

    btn.label = Theme.CreateText(btn, "bodySmall")
    btn.label:SetPoint("LEFT", btn, "LEFT", 0, 0)
    -- Room for the star on the right, the same gap the picker's rows leave.
    btn.label:SetPoint("RIGHT", btn, "RIGHT", -16, 0)
    btn.label:SetJustifyH("LEFT")
    btn.label:SetWordWrap(false)

    -- Favourite marker. Always the filled star; it is only ever shown on a row
    -- that IS a favourite, exactly as in the picker.
    btn.Star = btn:CreateTexture(nil, "OVERLAY")
    btn.Star:SetSize(11, 11)
    btn.Star:SetPoint("RIGHT", btn, "RIGHT", -3, 0)
    ApplyFavoriteIcon(btn.Star, true)
    btn.Star:Hide()

    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    Theme.FillColor(highlight, "stripeHover")

    -- Right-click has to be REGISTERED before it can be handled; without this
    -- the OnClick above only ever sees a left button, which is what made the
    -- favourite gesture silently dead in this list.
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnEnter", SuggestionEnter)
    btn:SetScript("OnLeave", SuggestionLeave)
    btn:SetScript("OnClick", SuggestionClick)
    btn:Hide()
    sf.buttons[i] = btn
  end

  return sf
end

-------------------------------------------------------------
-- 15b. A list that fills itself in
--
-- The guild roster and the friends list are server round trips. Open the picker
-- inside one -- which is exactly what the first mailbox after a login does --
-- and Guild is empty under an empty state that promises it "fills in on its
-- own". It did not: Core/ContactService.lua exports CS.Invalidate for a
-- listener to hang off and nothing ever did, so the list stayed empty until it
-- was closed and reopened by hand, and the sentence was a lie.
--
-- Now the sources' own events repopulate whatever is on screen IN PLACE: the
-- picker keeps its scroll offset (only opening it from the bar resets that),
-- the type-ahead keeps the query being typed, and the category bar's tiles
-- undim as their sources answer.
--
-- Cheap in the two ways that matter:
--
--   * The events are registered only while this tab is on screen (see
--     VISIBILITY_EVENTS) -- BN_FRIEND_INFO_CHANGED alone fires for every
--     presence tick of every Battle.net friend, all session long.
--   * The handler only marks. The pass runs once per frame at most, through the
--     same coalescer everything else here uses, and returns immediately unless
--     a list is actually open or the bar's dimming was decided before the
--     sources had answered.
-------------------------------------------------------------

function ContactsChanged(panel)
  local picker = panel.ContactPicker
  local pickerOpen = (picker and picker:IsShown()) and true or false
  local suggestOpen = (panel.SuggestFrame and panel.SuggestFrame:IsShown()) and true or false

  if not (pickerOpen or suggestOpen or panel._catEmptyProvisional) then return end

  local CS = Contacts()
  local ready = true
  if type(CS) == "table" and type(CS.SourcesReady) == "function" then
    local ok, answer = pcall(CS.SourcesReady)
    ready = (not ok) or (answer and true or false)
  end

  -- Still inside the round trip. The service coalesces repeat rebuilds of a
  -- source it built moments ago, so the snapshot it would hand back right now is
  -- the same empty one that is already on screen; CS.RefreshPending is its
  -- documented way past that window -- it dirties only the unanswered sources,
  -- throttles itself, and re-issues the requests so the state can resolve. A
  -- full Invalidate here would be a five-source rebuild per roster tick.
  if not ready and type(CS) == "table" and type(CS.RefreshPending) == "function" then
    CS.RefreshPending()
  end

  if pickerOpen then
    -- In place: PopulateContactPicker keeps the scroll offset (and clamps it if
    -- the list got shorter), and re-decides the bar's dimming from the same
    -- snapshot. Re-placed as well, because a list that grew from nothing to
    -- three hundred names wants the height it could not ask for before.
    PopulateContactPicker(picker)
    PlacePicker(panel, picker)
  elseif panel._catEmptyProvisional then
    RefreshCategoryEmptiness(panel)
  end

  if suggestOpen then RefreshSuggestions(panel) end

  RefreshContactBar(panel)
end

-------------------------------------------------------------
-- 16. Inputs
--
-- Every text input on this screen is the SAME thing: a card surface wrapping an
-- edit box, tagged for the host-UI skins by Theme.StyleInput. That includes the
-- three money boxes, which used to be raw InputBoxTemplate -- thin gold
-- brackets sitting ~120px from fields wearing the addon's own treatment, so one
-- screen read as two addons. Both skins unified them; nothing did on a stock UI.
-------------------------------------------------------------

local function PrepareEditBox(box, role)
  local font = Theme.FontObject(role or "bodySmall")
  if font then box:SetFontObject(font) end
  Theme.SetColor(box, "textPrimary")
  box:SetAutoFocus(false)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
end

-- THE SCROLL BAR BELONGS TO THE FIELD, not to the scroll frame inside it.
--
-- Left alone, the bar's position is the template's business: it hangs the
-- slider six pixels OUTSIDE the scroll frame's right edge and stands the two
-- end buttons a further ~16px beyond each end of it. Whether that assembly
-- lands inside the field then depends on the template's offsets continuing to
-- add up to the gutter this file reserves -- which is a coincidence to rely on,
-- and the kind that breaks silently on a client update or under a host UI that
-- swaps the bar for a different shape.
--
-- Anchored to the WRAP instead, inside the same gutter the text already gives up
-- (M.scrollGutter = offset + width + clearance) and clear of the field's own
-- padding at both ends, the bar is within the field's border at every window
-- height and in every state -- by construction rather than by arithmetic.
--
-- This is also what EllesmereUI's SkinScroll does to it, to the same frame and
-- within a pixel or two of the same numbers, so the stock and skinned paths now
-- put the bar in the same place instead of only one of them being deliberate.
local SCROLL_END_BUTTON = 16   -- fallback only; the button is measured first

local function PinScrollBarInside(wrap, scroll, pad)
  local bar = scroll.ScrollBar
  if not bar then return end

  -- The end buttons sit outside the slider's own anchors, so the slider has to
  -- start one button's height in from each edge for them to land inside.
  local up = bar.ScrollUpButton
  local room = (up and type(up.GetHeight) == "function" and ceil(up:GetHeight() or 0)) or 0
  if room < 1 then room = SCROLL_END_BUTTON end

  bar:ClearAllPoints()
  bar:SetWidth(M.scrollBarWidth)
  bar:SetPoint("TOPRIGHT", wrap, "TOPRIGHT", -M.scrollBarClearance, -(pad + room))
  bar:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -M.scrollBarClearance, pad + room)
end

-- A labelled field spanning the panel width. A multi-line field is left with no
-- height of its own: the message body is the screen's one elastic band and
-- ST.ApplyBodyBounds owns its vertical anchors.
local function CreateFieldRow(panel, anchorLabel, multiLine)
  local wrap = CreateFrame("Frame", nil, panel, "BackdropTemplate")
  wrap:SetPoint("TOPLEFT", anchorLabel, "BOTTOMLEFT", 0, -M.labelGap)
  wrap:SetPoint("RIGHT", panel, "RIGHT", -M.inset, 0)
  if not multiLine then wrap:SetHeight(M.controlHeight) end

  local box
  if multiLine then
    local scroll = CreateFrame("ScrollFrame", nil, wrap, "UIPanelScrollFrameTemplate")
    -- The scroll bar's gutter is reserved INSIDE the wrap: the bar belongs to
    -- the field, so it sits within the field's border rather than over it or
    -- outside it. Reserved permanently, and permanently the same width, so
    -- showing the bar never re-flows the text the user is reading.
    scroll:SetPoint("TOPLEFT", wrap, "TOPLEFT", M.inset, -BODY_PAD)
    scroll:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -M.scrollGutter, BODY_PAD)

    box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    -- The scroll frame is anchor-sized and so reads 0 until the first layout
    -- pass; derive the text width from the wrap (and, failing that, the panel)
    -- rather than letting the first paint wrap at the wrong width.
    local textWidth = scroll:GetWidth() or 0
    if textWidth <= 1 then
      textWidth = max(ResolvedWidth(wrap, panel, M.inset) - M.inset - M.scrollGutter, 1)
    end
    box:SetWidth(textWidth)
    scroll:SetScrollChild(box)

    -- The bar is only on screen when there is something to scroll. The template
    -- reads `scrollBarHideable` for exactly this; the explicit pass below does
    -- not depend on that, because a bar whose two end buttons alone want ~32px
    -- is the thing that visibly bled out of a short field.
    --
    -- And the bar is now a rarity rather than the normal state of a second
    -- line: the window grows with the message (section 16b), so the box only
    -- scrolls once that growth has run out of screen. The bar appearing means
    -- "this is as tall as the window gets", which is worth seeing.
    scroll.scrollBarHideable = true
    local function UpdateScrollBar()
      local range = scroll:GetVerticalScrollRange() or 0
      -- The window growing under the text is a range that just SHRANK, and an
      -- offset left over from before the growth would hold the message scrolled
      -- with blank space beneath it -- the cursor having been followed down a
      -- line that then stopped needing to be scrolled to. The template clamps
      -- through its scroll bar, but only while the bar is a slider it owns;
      -- clamping here does not depend on that.
      if (scroll:GetVerticalScroll() or 0) > range then
        scroll:SetVerticalScroll(max(0, range))
      end
      local bar = scroll.ScrollBar
      if not bar then return end
      bar:SetShown(range > 1)
    end
    PinScrollBarInside(wrap, scroll, BODY_PAD)
    scroll:HookScript("OnScrollRangeChanged", UpdateScrollBar)
    UpdateScrollBar()

    -- The body re-flows its text width on resize -- and a re-flow changes how
    -- many LINES the message occupies, so the window's height has to be asked
    -- for again. Only on a genuine width change: a height change is what that
    -- answer produced, and re-asking on it would be a second pass per line.
    scroll:SetScript("OnSizeChanged", function(_, w)
      if w and w > 10 and w ~= box:GetWidth() then
        box:SetWidth(w)
        Invalidate(panel, "body")
      end
      UpdateScrollBar()
    end)

    -- Typing must not run off the bottom of the field. The window growing with
    -- the message (section 16b) is the first answer and covers the normal case;
    -- this is the second, and it is what holds once the window has hit the
    -- bottom of the screen and the box genuinely has to scroll -- and for every
    -- cursor move that is not a text change, where nothing has grown at all.
    -- Deferred by one frame because the edit box has not re-measured itself --
    -- and the scroll range is still the old one -- at the moment the cursor
    -- moves.
    local function FollowCursor()
      box:SetScript("OnUpdate", nil)
      local cursorY, cursorH = box._cursorY, box._cursorHeight
      box._cursorY, box._cursorHeight = nil, nil
      if type(cursorY) ~= "number" then return end

      local view = scroll:GetHeight() or 0
      if view <= 0 then return end

      local top    = -cursorY                      -- from the box's top edge
      local bottom = top + (tonumber(cursorH) or 0)
      local offset = scroll:GetVerticalScroll() or 0
      local target = offset
      if top < offset then
        target = top
      elseif bottom > offset + view then
        target = bottom - view
      end

      target = max(0, min(target, scroll:GetVerticalScrollRange() or 0))
      if target ~= offset then scroll:SetVerticalScroll(target) end
      UpdateScrollBar()
    end

    box:SetScript("OnCursorChanged", function(self, _, cursorY, _, cursorHeight)
      self._cursorY, self._cursorHeight = cursorY, cursorHeight
      self:SetScript("OnUpdate", FollowCursor)
    end)

    wrap._scroll = scroll
  else
    box = CreateFrame("EditBox", nil, wrap)
    box:SetHeight(M.controlHeight)
    box:SetPoint("TOPLEFT", wrap, "TOPLEFT", M.inset, -M.tightGap)
    box:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -M.gap, M.tightGap)
  end

  PrepareEditBox(box)
  -- One card surface, both skin tags, set in one place.
  Theme.StyleInput(wrap, box)
  -- The padding around the box is part of the field as far as the user is
  -- concerned. Without EnableMouse the wrap receives nothing and clicking just
  -- inside the border does nothing at all.
  wrap:EnableMouse(true)
  wrap:SetScript("OnMouseDown", function() box:SetFocus() end)

  return wrap, box
end

-- THE ELASTIC BAND (section 1). The message body absorbs every pixel the fixed
-- bands leave, and never goes below MessageMinHeight().
--
-- Two modes, and the second should be unreachable:
--
--   stretched  the normal state. The wrap is anchored between its caption and
--              the attachment area, so EVERY pixel a taller window adds lands
--              here and nowhere else.
--   floored    only if something has put the panel below ST.MinPanelHeight()
--              regardless -- a host UI with a much taller font, or a saved size
--              from a build whose bands differed. The message keeps its lines
--              and the band beneath is what gets crowded, because a message box
--              collapsed to nothing is precisely the failure the derived floor
--              exists to prevent.
--
-- Called on every panel resize, on every change to the attachment rows, and once
-- at build. Growing the WINDOW (section 16b) does not change which of the two
-- modes applies -- extra height only ever makes the stretched state more true --
-- so the early-out below means an auto-grow step re-anchors nothing.
function ST.ApplyBodyBounds(panel)
  local wrap = panel and panel.BodyWrap
  if not wrap or not panel.ItemArea or not panel.MessageLabel then return end

  local minHeight = MessageMinHeight()
  -- A frame sized only by its anchors reads 0 until the first layout pass. An
  -- unmeasurable panel means the normal state -- which is what the window's
  -- derived floor guarantees anyway.
  local panelHeight = panel:GetHeight() or 0
  local stretched = (panelHeight <= 1)
    or ((panelHeight - PanelHeightFor(0, panel._attachRows)) >= minHeight)

  if stretched == wrap._stretched then return end
  wrap._stretched = stretched

  wrap:ClearAllPoints()
  wrap:SetPoint("TOPLEFT", panel.MessageLabel, "BOTTOMLEFT", 0, -M.labelGap)
  wrap:SetPoint("RIGHT", panel, "RIGHT", -M.inset, 0)
  if stretched then
    -- Zero clears the explicit height so the two anchors decide it.
    wrap:SetHeight(0)
    wrap:SetPoint("BOTTOM", panel.ItemArea, "TOP", 0, BAND_GAP)
  else
    wrap:SetHeight(minHeight)
  end
end

-------------------------------------------------------------
-- 16b. The window grows with the message
--
-- Typing past the bottom of the message box used to scroll the text and pop a
-- scroll bar into a field a handful of lines tall. Instead the WINDOW gets
-- taller -- and it is what makes MESSAGE_MIN_LINES a floor nobody meets: one
-- line of window per line of message, as the line appears, and shorter again as
-- lines are deleted. Nothing above or below the message box moves -- the body is
-- the screen's one elastic band (section 1), so every pixel the window gains
-- lands in it and nowhere else.
--
-- Four rules, and all four are about not fighting the user:
--
--   BASE      the height the user chose -- dragged with the grip, or restored
--             from the last session -- is untouched. The extension is an
--             overlay Core/MailboxUI.lua layers on top of it and subtracts
--             again before every save, so the window never reopens taller than
--             it was chosen to be, and it never shrinks BELOW the base however
--             short the message gets.
--   CLAMPED   growth stops at the bottom of the screen. Whatever the message
--             did not get, it scrolls for -- and that is the only state in
--             which the scroll bar appears at all.
--   THE GRIP  WINS. The shell folds the extension into the base the moment the
--             grip is grabbed (nothing moves under the cursor), and the
--             overflow standing when the drag ENDS becomes SLACK: text the
--             user has decided to scroll rather than to see. Without that, a
--             drag that made the window shorter would be undone by an
--             immediate re-inflate, which is precisely the wrestling match an
--             earlier design was rejected for.
--   QUANTISED to whole lines of the body font, so the window steps in the same
--             units the text does rather than by an arbitrary few pixels.
--
-- The slack DECAYS with the text: delete down to less overflow than was
-- accepted and the accepted amount comes down with it, so typing grows the
-- window again from wherever the user left it rather than being permanently
-- capped by one drag.
-------------------------------------------------------------

-- One rendered line of the body font, INCLUDING whatever leading the renderer
-- puts between two lines: two lines' measured height less one line's. Both
-- halves are cached by TextHeight, so this is two table lookups after the first
-- call. Never a hardcoded pixel count -- the whole point of section 1.
local function BodyLineStep()
  local step = TextHeight("bodySmall", 2) - TextHeight("bodySmall", 1)
  if step < 1 then step = TextHeight("bodySmall", 1) end
  return max(1, step)
end

-- True from the instant the resize grip is pressed until it is released. Module
-- scope rather than per-panel because there is exactly one window, and the flag
-- is about the grip rather than about the screen.
local elasticSuspended = false

-- What the extension is contributing to the field's height at this instant,
-- asked of the shell every time rather than remembered here. The shell clamps
-- what it grants -- at the screen's edge, and again whenever an attachment row
-- moves the window -- so a remembered answer would be wrong from the first
-- clamp onwards, and every measurement below is taken relative to it.
local function AppliedExtension()
  local UI = ns.MailboxUI
  if not (UI and UI.GetMessageExtraHeight) then return 0 end
  return tonumber((UI.GetMessageExtraHeight())) or 0
end

-- How much of the message does not fit in the room the user's OWN height gives
-- it, in pixels. nil means "not measurable yet" -- a frame sized only by its
-- anchors reads 0 until the first layout pass, and resizing the window on a
-- guess is worse than not resizing it at all.
local function BodyOverflow(panel)
  local wrap = panel and panel.BodyWrap
  local scroll = wrap and wrap._scroll
  local box = panel and panel.BodyBox
  if not (scroll and box) then return nil end

  -- Floored bounds pin the wrap at a fixed height, so window growth would no
  -- longer reach the field 1:1 and the "base = viewport - applied" identity
  -- below inverts into positive feedback: every step would shrink the apparent
  -- base and ask for another step, until the screen edge. Unreachable with
  -- today's derived floor, but that is exactly the mode's job to survive.
  if wrap._stretched == false then return nil end

  local viewport = scroll:GetHeight() or 0
  if viewport <= 1 then return nil end

  -- A multi-line edit box inside a scroll frame sizes its own height to its
  -- text; that height IS the answer to "how tall is this message".
  local content = box:GetHeight() or 0
  if content <= 0 then return nil end

  -- What the field would have at the user's base height: what it has now, less
  -- whatever the extension is currently contributing. Exact rather than
  -- approximate, because the body absorbs the window's extra height 1:1.
  local base = viewport - AppliedExtension()
  if base <= 0 then return nil end

  return max(0, content - base)
end

function ApplyElasticHeight(panel)
  -- The grip owns the height until it lets go.
  if elasticSuspended then return end
  if not panel or not panel:IsShown() then return end

  local UI = ns.MailboxUI
  if not (UI and UI.SetMessageExtraHeight) then return end

  local overflow = BodyOverflow(panel)
  if not overflow then return end

  if panel._elasticRebaseline then
    -- The grip has just been released. Whatever does not fit at the size the
    -- user settled on is the size they chose to settle for.
    panel._elasticRebaseline = nil
    panel._elasticSlack = overflow
    return
  end

  local slack = panel._elasticSlack or 0
  if overflow < slack then
    slack = overflow
    panel._elasticSlack = slack
  end

  local step = BodyLineStep()
  local wanted = overflow - slack
  wanted = (wanted > 0) and (ceil(wanted / step) * step) or 0

  if wanted == AppliedExtension() then return end

  -- Resizing the window re-enters this panel's own OnSizeChanged, which closes
  -- every list on screen. That handler is for a DRAG, where each list is
  -- anchored to a control that has just moved; a line of growth under somebody's
  -- cursor is not that.
  --
  -- Stamped with the FRAME rather than set-and-cleared around the call: whether
  -- a child's OnSizeChanged is dispatched inside SetHeight or at the end of the
  -- same frame's layout pass is the engine's business, not ours, and GetTime()
  -- is constant across a frame either way.
  panel._autoGrowAt = (type(GetTime) == "function") and GetTime() or nil
  -- Whatever the shell grants -- growth is clamped at the bottom of the screen
  -- and at the resize grip's own ceiling -- is what AppliedExtension reports
  -- from here on, so the next pass measures against reality rather than against
  -- what this one asked for.
  UI.SetMessageExtraHeight(wanted)
end

-- The resize grip, through Core/MailboxUI.lua: pressed, then released.
--
-- On release the baseline is re-read one frame LATER, not now: the text has to
-- re-wrap at the new width before "how much does not fit" means anything, and
-- the coalescer is the thing that already runs a frame after the fact.
function ST.SuspendElastic(suspended, cancelled)
  elasticSuspended = suspended and true or false
  if elasticSuspended then return end

  local panel = ActivePanel()
  if not panel then return end

  -- The grip belongs to the window, not to a tab. A drag made from the Collect
  -- tab has nothing to rebaseline HERE: this panel's OnHide already dropped its
  -- extension, so a rebaseline flag left on the hidden panel would count the
  -- draft's whole overflow as chosen slack the next time it is shown, and the
  -- window would refuse to grow for that draft at all.
  if not panel:IsShown() then return end

  -- A press that never moved changed nothing: the shell restored the adopted
  -- extension, and re-reading the baseline now would convert it into slack.
  if cancelled then return end

  -- The shell folded the extension into the base as the drag began -- so the
  -- field's whole height belongs to the user now, and AppliedExtension already
  -- reads zero. All that is left is to re-read what does not fit at it.
  panel._elasticRebaseline = true
  Invalidate(panel, "body")
end

-- 16c. THE DRAG FLOOR RESPECTS WHAT IS ALREADY TYPED.
--
-- The grip wins over the elastic extension (16b) -- but "wins" meant it could be
-- dragged straight down to the derived floor with a message standing in the box,
-- which put a scroll bar over text the window had been made tall enough to show
-- a moment earlier. The window is allowed to be shorter than its message; it
-- should not be shorter than its message BY ACCIDENT, in one gesture, because
-- the floor was computed for an empty draft.
--
-- So for the duration of one drag the floor rises to keep the standing text on
-- screen -- by at most MESSAGE_DRAG_LINES lines. Past that the box scrolls,
-- which is the state its scroll bar exists for, and the drag reaches the derived
-- floor plus those lines rather than the derived floor itself.
--
-- MESSAGE_DRAG_LINES is INDEPENDENT of MESSAGE_MIN_LINES and is measured from
-- the derived floor, not from the field's own height: the two compose, so a
-- drag protects whatever the floor already guarantees PLUS these lines. Nothing
-- below reads or restates the message minimum, which is why lowering it moved
-- this behaviour by exactly the amount the floor moved and by nothing else.
--
-- Three things make this safe to compose with everything else in this file:
--
--   * It is a FLOOR, never a height. Nothing here grows the window; the most it
--     can do is stop a drag early. Growth is 16b's job and stays quantised and
--     slack-aware.
--   * It is capped at `shrinkRoom` -- how much the drag could take away at all
--     -- so it can never exceed the height the window already has, and a grab
--     made to enlarge a window that is ALREADY shorter than its text cannot
--     jerk it taller on mouse-down.
--   * The overflow standing at the settled height still becomes slack on
--     release (ST.SuspendElastic -> _elasticRebaseline), so a drag that stops at
--     the cap is not undone by an immediate re-inflate. Delete the text and the
--     slack decays with it, exactly as before.
--
-- Answered ONCE, at the instant the grip is pressed: the message cannot change
-- mid-gesture, and a per-frame answer would be a floor moving under the cursor.
-- (A drag that also narrows the window re-wraps the text into more lines than
-- were measured here; that is the one case this deliberately does not chase,
-- because chasing it means the floor fighting the drag.)
local MESSAGE_DRAG_LINES = 4

-- `shrinkRoom` is what the drag is free to take off the window's height before
-- it meets the derived floor. Returns how much of that must be withheld to keep
-- the standing message visible, in whole lines of the body font.
function ST.MessageFloorExtra(shrinkRoom)
  shrinkRoom = tonumber(shrinkRoom) or 0
  if shrinkRoom <= 0 then return 0 end

  local panel = ActivePanel()
  if not (panel and panel:IsShown()) then return 0 end

  local wrap = panel.BodyWrap
  local scroll = wrap and wrap._scroll
  local box = panel.BodyBox
  if not (scroll and box) then return 0 end
  -- Floored bounds: the body no longer absorbs the window's height 1:1, so the
  -- arithmetic below does not describe this panel. Same guard as BodyOverflow.
  if wrap._stretched == false then return 0 end

  local viewport = scroll:GetHeight() or 0
  if viewport <= 1 then return 0 end
  local content = box:GetHeight() or 0
  if content <= 0 then return 0 end

  -- What the field would be left with if the drag went the whole way down.
  local short = content - (viewport - shrinkRoom)
  if short <= 0 then return 0 end

  -- Whole lines, so the floor lands on the same grid the elastic growth steps
  -- on and a drag cannot stop half a line above one.
  local step = BodyLineStep()
  short = ceil(short / step) * step

  return max(0, min(short, MESSAGE_DRAG_LINES * step, shrinkRoom))
end

-- A numeric money box. Fixed width is safe here and only here: the content is
-- digits, not a translated caption.
local function CreateMoneyInput(parent, anchor, width, maxLetters)
  local wrap = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  wrap:SetSize(width, MONEY_INPUT_H)
  wrap:SetPoint("LEFT", anchor, "RIGHT", M.tightGap, 0)

  local box = CreateFrame("EditBox", nil, wrap)
  box:SetPoint("TOPLEFT", wrap, "TOPLEFT", M.tightGap, -2)
  box:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -M.tightGap, 2)
  box:SetNumeric(true)
  box:SetMaxLetters(maxLetters)
  box:SetJustifyH("RIGHT")

  PrepareEditBox(box, "value")
  Theme.StyleInput(wrap, box)
  wrap:EnableMouse(true)
  wrap:SetScript("OnMouseDown", function() box:SetFocus() end)

  return wrap, box
end

-- Ghost text for an empty field. Never sent: it is a font string over the box,
-- not the box's contents.
local function AttachPlaceholder(wrap, box, text, multiLine)
  local ph = Theme.CreateText(wrap, "placeholder")
  -- Anchored on the same insets as the box it stands in for, so the ghost text
  -- and the real text sit on the same line rather than a pixel or two apart.
  local topInset    = multiLine and BODY_PAD or M.tightGap
  local bottomInset = topInset
  local rightInset  = multiLine and M.scrollGutter or M.inset
  ph:SetPoint("TOPLEFT", wrap, "TOPLEFT", M.inset, -topInset)
  ph:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -rightInset, bottomInset)
  ph:SetJustifyH("LEFT")
  ph:SetJustifyV(multiLine and "TOP" or "MIDDLE")
  ph:SetWordWrap(multiLine and true or false)
  ph:SetText(text)
  box._placeholder = ph
  return ph
end

local function CreateFieldLabel(parent, anchor, relative, offsetX, offsetY, text)
  local fs = Theme.CreateText(parent, "label")
  fs:SetPoint("TOPLEFT", anchor, relative, offsetX, offsetY)
  -- Given the measured height of its own font rather than left to size itself:
  -- every field below a caption is anchored to that caption's bottom edge, so
  -- the height sum in section 1 is only honest if the captions are exactly as
  -- tall as it says they are. One line, never wrapped -- the font string has no
  -- width constraint, which is also what stops a long translation clipping.
  fs:SetHeight(LabelHeight())
  fs:SetText(text)
  return fs
end

-------------------------------------------------------------
-- 17. Bag overlays
--
-- While the compose screen is active, every bag slot holding something that
-- cannot be mailed is greyed with a padlock, so the player sees at a glance
-- what is attachable.
--
-- The attachability verdict, its GUID memo and its invalidation live in
-- Lib/InventoryLock.lua. What is owned here is the hooking policy: only VISIBLE
-- bag buttons are hooked, each is hooked once for the session, and the marked
-- ones are tracked in a set so unmarking is O(marked) rather than O(all slots).
-- Both tables are weak-keyed so a container frame the client rebuilds is not
-- pinned by us.
-------------------------------------------------------------

local InventoryLock = ns.Core.InventoryLock
local sendTabActive = false
local overlaid    = setmetatable({}, { __mode = "k" })
local hookedSlots = setmetatable({}, { __mode = "k" })

local function ClearOverlay(button)
  if not overlaid[button] then return end
  InventoryLock.UnmarkButton(button)
  overlaid[button] = nil
end

local function ClearEveryOverlay()
  for button in pairs(overlaid) do
    InventoryLock.UnmarkButton(button)
    overlaid[button] = nil
  end
end

-- The body of the hook below. It runs on whatever the client considers a
-- reason to repaint a slot, so it has to be cheap and it has to cope with
-- slots outside the backpack chain (bank, reagent bank, warband tabs) turning
-- up: those get no verdict and no padlock.
local function RefreshSlotOverlay(button)
  if not sendTabActive then
    ClearOverlay(button)
    return
  end

  local bag, slot = button:GetBagID(), button:GetID()
  local unmailable = bag and slot
    and slot >= 1
    and bag >= 0 and bag <= (NUM_TOTAL_BAG_FRAMES or 4)
    and InventoryLock.ShouldLockForMail(bag, slot)

  if unmailable then
    InventoryLock.MarkButton(button)
    overlaid[button] = true
  else
    ClearOverlay(button)
  end
end

-- Anything claiming to be an item button has to prove it can name its own
-- slot and that it has the repaint entry point we intend to ride; addons that
-- replace the bags wholesale supply frames that pass neither.
local function IsSlotButton(button)
  return type(button) == "table"
     and type(button.GetBagID) == "function"
     and type(button.GetID) == "function"
     and type(button.UpdateItemContextMatching) == "function"
end

-- hooksecurefunc has no counterpart, so a button hooked twice would run the
-- verdict twice for the rest of the session. Hence the set, and hence the
-- flag going down before the hook is installed rather than after.
local function HookSlot(button)
  if not IsSlotButton(button) or hookedSlots[button] then return end
  hookedSlots[button] = true
  hooksecurefunc(button, "UpdateItemContextMatching", RefreshSlotOverlay)
end

local function IsOnScreen(frame)
  return type(frame) == "table" and frame.IsShown and frame:IsShown()
end

-- Every button the frame owns, including the pooled ones parked beyond the
-- current bag size.
local function HookPooledSlots(frame)
  if not IsOnScreen(frame) or type(frame.Items) ~= "table" then return end
  for _, button in ipairs(frame.Items) do HookSlot(button) end
end

-- Only the buttons the frame currently counts as in range. Preferred where the
-- client offers it, because it skips the pooled tail.
local function HookLiveSlots(frame)
  if not IsOnScreen(frame) then return end
  if type(frame.EnumerateValidItems) == "function" then
    for _, button in frame:EnumerateValidItems() do HookSlot(button) end
  else
    HookPooledSlots(frame)
  end
end

local function HookVisibleSlots()
  local Enumerate = ContainerFrameUtil_EnumerateContainerFrames
  if type(Enumerate) == "function" then
    for _, frame in Enumerate() do HookLiveSlots(frame) end
  end

  -- Swept on its own and by pool rather than by range: the enumerator lists
  -- this frame only while the combined layout is the active one, and its
  -- buttons are recycled across bag-size changes we do not get told about.
  HookPooledSlots(ContainerFrameCombinedBags)

  -- Fallback for a client with no enumerator. Walked by name until the names
  -- run out -- the client numbers these from 1 with no gaps -- so the sweep
  -- neither hard-codes a count that ages nor pokes at frames never created.
  local index = 1
  while true do
    local frame = _G["ContainerFrame" .. index]
    if not frame then break end
    HookPooledSlots(frame)
    index = index + 1
  end
end

-- One container repaint per user action: the hooks do the marking, this only
-- asks the client to run them.
local function RepaintContainers()
  if type(ContainerFrame_UpdateAll) == "function" then ContainerFrame_UpdateAll() end
end

function ST.UpdateBagOverlays()
  HookVisibleSlots()
  RepaintContainers()
end

function ST.ClearBagOverlays()
  sendTabActive = false
  ClearEveryOverlay()
  RepaintContainers()
end

-------------------------------------------------------------
-- 18. Native send-mail state
--
-- We deliberately do NOT show/hide the native SendMailFrame / InboxFrame or
-- call PanelTemplates_SetTab. Those are protected frames owned by the secure
-- PlayerInteractionFrameManager; touching them from insecure code TAINTS them
-- permanently (even out of combat), which then makes Blizzard's own
-- mailbox-open path and the Escape interaction-close fail in combat. The native
-- frames stay invisible behind our UI regardless, and SetSendMailShowing -- a
-- plain, non-frame, taint-free API -- is all that right-click-to-attach
-- actually needs. See COMBAT_TAINT.md.
-------------------------------------------------------------

-- Whether Postbox currently wants the client's right-click-to-attach armed.
-- Flipped BEFORE the flag itself moves, because the guard below reads it.
local nativeArmWanted = false

-- The guard. Arming once is not enough: Blizzard's own mailbox-open path
-- runs AFTER our MAIL_SHOW handler and re-runs its inbox-tab logic, which
-- calls SetSendMailShowing(false) -- so the flag we had just armed was quietly
-- dropped, and a bag right-click went back to USING the item (a potion was
-- drunk, a BoE tried to equip). The open-sequence ordering is not ours to
-- win, so instead of racing it: whenever ANY caller drops the flag while
-- Postbox wants it armed, it is re-asserted on the spot. hooksecurefunc, so
-- the secure caller is untouched; the latch keeps our own re-assert from
-- re-entering the hook.
local reasserting = false
if type(hooksecurefunc) == "function" and type(SetSendMailShowing) == "function" then
  hooksecurefunc("SetSendMailShowing", function(shown)
    if shown or not nativeArmWanted or reasserting then return end
    reasserting = true
    pcall(SetSendMailShowing, true)
    reasserting = false
  end)
end

function ST.ActivateNativeSendMail()
  sendTabActive = true
  nativeArmWanted = true
  if type(SetSendMailShowing) == "function" then SetSendMailShowing(true) end
  HookVisibleSlots()
  RepaintContainers()
end

-- The flag alone, without the compose overlays: what the collect tab arms
-- while quick attach is on, so a bag right-click attaches from there too.
-- sendTabActive stays down on purpose -- the padlock overlays belong to the
-- compose screen, and a collect visit's BAG_UPDATE storm should not be paying
-- for mailability verdicts nobody is looking at.
function ST.ArmNativeSendMail()
  nativeArmWanted = true
  if type(SetSendMailShowing) == "function" then SetSendMailShowing(true) end
end

function ST.DeactivateNativeSendMail()
  sendTabActive = false
  -- Down BEFORE the flag moves, or the guard would re-arm our own disarm.
  nativeArmWanted = false
  if type(SetSendMailShowing) == "function" then SetSendMailShowing(false) end
  ClearEveryOverlay()
  RepaintContainers()
end

-------------------------------------------------------------
-- 18a. The attachment queue
--
-- Twelve slots is the server's limit per mail, not a limit on what a player
-- wants to post. With every slot full, a right-click on a bag item used to be
-- refused by the client and forgotten by Postbox. Now the item is queued: it
-- waits under the slots, counted, and goes out after this mail -- twelve at a
-- time, to the same recipient with the same subject and message -- with one
-- press of Send. Gold and C.O.D. belong to the first mail only; while a
-- C.O.D. price is armed nothing is queued at all, because a price per mail
-- is not something to guess at.
--
-- The client's own right-click is the only way in. C_Container.UseContainerItem
-- is post-hooked (a secure hook; the click itself runs untouched, and this
-- runs after it) and, with the Send tab showing and every slot taken, the
-- item the client refused is queued. Whenever a slot frees -- an attachment
-- removed, a mail sent -- the queue moves in, so the slots and the queue
-- together are one list in the order the items were clicked.
--
-- The queue holds bag positions, each with the item's GUID. A bag can be
-- sorted between two mails, so an item is attached only where the GUID still
-- agrees with the position -- or has been found again elsewhere in the bags.
--
-- Nothing here is combat-sensitive: PickupContainerItem, ClickSendMailItemButton
-- and SendMail are plain C APIs, and a mailbox cannot be open in combat anyway.
-------------------------------------------------------------

local function Queue(panel)
  local queue = panel._queue
  if not queue then
    queue = {}
    panel._queue = queue
  end
  return queue
end

local function GuidAt(bag, slot)
  if type(ItemLocation) ~= "table" or type(ItemLocation.CreateFromBagAndSlot) ~= "function" then return nil end
  if not (C_Item and type(C_Item.GetItemGUID) == "function") then return nil end
  local ok, location = pcall(ItemLocation.CreateFromBagAndSlot, bag, slot)
  if not ok or not location then return nil end
  local okGuid, guid = pcall(C_Item.GetItemGUID, location)
  return (okGuid and type(guid) == "string") and guid or nil
end

local function ContainerInfo(bag, slot)
  if not (C_Container and type(C_Container.GetContainerItemInfo) == "function") then return nil end
  local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
  return (ok and type(info) == "table") and info or nil
end

local LAST_BAG = (type(NUM_TOTAL_EQUIPPED_BAG_SLOTS) == "number" and NUM_TOTAL_EQUIPPED_BAG_SLOTS)
  or (type(NUM_BAG_SLOTS) == "number" and NUM_BAG_SLOTS) or 4

-- Where the entry's item is now: its own position when the GUID there still
-- agrees, otherwise wherever the bags hold that GUID, otherwise nowhere.
local function Locate(entry)
  if GuidAt(entry.bag, entry.slot) == entry.guid then return entry.bag, entry.slot end
  if not (C_Container and type(C_Container.GetContainerNumSlots) == "function") then return nil end
  for bag = 0, LAST_BAG do
    local ok, count = pcall(C_Container.GetContainerNumSlots, bag)
    for slot = 1, (ok and tonumber(count)) or 0 do
      if GuidAt(bag, slot) == entry.guid then return bag, slot end
    end
  end
  return nil
end

-- The queue's face: the count beside the attachments label and the Send
-- button's caption. Both read the queue, so both are refreshed from here.
RefreshQueueLabel = function(panel)
  if not panel then return end
  local queue = panel._queue
  local waiting = queue and #queue or 0
  local button = panel.QueueLabel
  if button then
    if waiting > 0 then
      button.Text:SetText(ns.Plural("COUNT_QUEUED", waiting))
      button:SetWidth((button.Text:GetStringWidth() or 0) + 4)
      button:Show()
    else
      button:Hide()
    end
  end
  if panel.FillButton and not pendingSend then
    panel.FillButton:SetText(SendButtonCaption(panel))
  end
end

local function Enqueue(panel, bag, slot)
  local info = ContainerInfo(bag, slot)
  -- Locked means the click DID attach it, or something else holds it.
  if not info or info.isLocked then return false end
  local guid = GuidAt(bag, slot)
  if not guid then return false end

  local queue = Queue(panel)
  for i = 1, #queue do
    if queue[i].guid == guid then return false end
  end

  -- The same verdict the padlock overlays draw from: an item that cannot be
  -- mailed is not queued to fail later.
  local Lock = ns.Core and ns.Core.InventoryLock
  if Lock and type(Lock.ShouldLockForMail) == "function" and Lock.ShouldLockForMail(bag, slot) then
    return false
  end

  queue[#queue + 1] = {
    bag = bag, slot = slot, guid = guid,
    link = info.hyperlink, count = info.stackCount,
  }
  RefreshQueueLabel(panel)
  return true
end

-- Moves queued items into free slots, first to last, until the slots are full
-- or the queue is empty. Returns how many were attached and how many had to
-- be dropped because their item could not be found any more.
local function FillFromQueue(panel)
  local queue = panel._queue
  if not queue or #queue == 0 then return 0, 0 end
  if not (C_Container and type(C_Container.PickupContainerItem) == "function") then return 0, 0 end
  if type(ClickSendMailItemButton) ~= "function" then return 0, 0 end
  -- The player is mid-drag; their item comes first.
  if type(CursorHasItem) == "function" and CursorHasItem() then return 0, 0 end

  local attached, missing = 0, 0
  local slotIndex = 1
  while #queue > 0 do
    while slotIndex <= SEND_SLOT_COUNT and SlotHasItem(slotIndex) do
      slotIndex = slotIndex + 1
    end
    if slotIndex > SEND_SLOT_COUNT then break end

    local entry = table.remove(queue, 1)
    local bag, slot = Locate(entry)
    if not bag then
      missing = missing + 1
    else
      pcall(C_Container.PickupContainerItem, bag, slot)
      pcall(ClickSendMailItemButton, slotIndex)
      -- The item still on the cursor is the client's refusal. Put it down,
      -- put the entry back at the front, and stop: whatever refused it will
      -- refuse the next one too.
      if type(CursorHasItem) == "function" and CursorHasItem() then
        if type(ClearCursor) == "function" then ClearCursor() end
        table.insert(queue, 1, entry)
        break
      end
      attached = attached + 1
      slotIndex = slotIndex + 1
    end
  end

  RefreshQueueLabel(panel)
  return attached, missing
end

-- What the slot refresh calls: a free slot is the queue's, unless a send is
-- in flight -- then the slots belong to the mail the server is holding.
TopUpFromQueue = function(panel)
  if pendingSend then return end
  local queue = panel and panel._queue
  if not queue or #queue == 0 then return end
  if AttachmentCount() >= SEND_SLOT_COUNT then return end
  local _, missing = FillFromQueue(panel)
  if missing > 0 then ns.Print(ns.Plural("MSG_QUEUE_MISSING", missing)) end
end

-- One more mail of the same press: whatever the queue has just put in the
-- slots, to the same recipient with the same subject and message, and no
-- money -- gold and C.O.D. went with the first.
local function SendQueued(panel, toName)
  local subject = FieldText(panel.SubjectBox)
  local body    = FieldText(panel.BodyBox)
  if subject == "" then subject = L["DEFAULT_NO_SUBJECT"] end

  ClearSendMailMoneyState()

  sendToken = sendToken + 1
  local myToken = sendToken
  pendingSend = { panel = panel, toName = toName, token = myToken }
  SetSendButtonBusy(panel, true)

  SendMail(toName, subject, body)

  C_Timer.After(SEND_TIMEOUT, function()
    if pendingSend and pendingSend.token == myToken then
      FinishSend("timeout")
    end
  end)
end

-- Called from FinishSend on success. True when the queue has taken over the
-- draft: the next mail will go out, and the draft will be settled from here
-- when the last one has. False when there is nothing queued, and the caller
-- settles the draft as it always did.
ContinueQueue = function(panel, pending)
  local queue = panel and panel._queue
  if not queue or #queue == 0 then return false end
  local UI = ns.MailboxUI
  if UI and type(UI.IsMailboxOpen) == "function" and not UI.IsMailboxOpen() then return false end

  local toName = pending.toName
  -- A moment later, not now: the server has confirmed the send, and the
  -- client empties the slots on its own schedule. A fifth of a second is
  -- well clear of it and invisible against the round trip just made.
  C_Timer.After(0.2, function()
    -- Something else took the draft meanwhile: a send the player started, or
    -- the mailbox closing, which empties the queue.
    if pendingSend then return end
    if UI and type(UI.IsMailboxOpen) == "function" and not UI.IsMailboxOpen() then return end

    local function Settle()
      SettleDraftAfterSuccess(panel)
      Invalidate(panel, "slots")
      Invalidate(panel, "cost")
      Invalidate(panel, "guidance")
    end

    -- The player emptied the queue in the meantime: the press is complete.
    if not panel._queue or #panel._queue == 0 then
      Settle()
      return
    end

    local attached, missing = FillFromQueue(panel)
    if missing > 0 then ns.Print(ns.Plural("MSG_QUEUE_MISSING", missing)) end

    if attached == 0 and AttachmentCount() == 0 then
      -- Nothing could be attached. The queue keeps whatever it still holds
      -- so the player can see what did not go, and the draft settles.
      local left = #(panel._queue or {})
      if left > 0 then ns.Print(ns.Plural("MSG_QUEUE_LEFT", left)) end
      Settle()
      return
    end

    SendQueued(panel, toName)
  end)
  return true
end

-- How many times each way in fired, and what came of it: the queue has
-- failed silently in the field once already, and the report is where the
-- next such report answers itself. ST.Diagnose renders them.
local queueStats = { click = 0, use = 0, refused = 0, queued = 0 }

-- The state in which a refused bag click can only mean "the slots are full":
-- the Send tab showing, no send in flight, no C.O.D. armed, every slot
-- taken. Every way in asks this first.
local function QueueOpen()
  if not sendTabActive or pendingSend then return nil end
  local panel = ActivePanel()
  if not panel or not panel:IsShown() then return nil end
  if IsCODArmed(panel) then return nil end
  if AttachmentCount() < SEND_SLOT_COUNT then return nil end
  return panel
end

local function TryEnqueue(panel, bag, slot)
  if type(bag) ~= "number" or type(slot) ~= "number" then return end
  if Enqueue(panel, bag, slot) then queueStats.queued = queueStats.queued + 1 end
end

-- The way in: the client's own right-click, after the client has answered
-- it. ContainerFrameItemButton_OnClick is the global every container button
-- built on Blizzard's template dispatches to -- the client's own bags, and
-- the bag addons that reuse the template -- and it is looked up by name at
-- call time, so a post-hook on it sees every such click. (The first build
-- hooked C_Container.UseContainerItem instead, which a bag addon that had
-- captured the function into a local at load never called through; that
-- hook stays, for a caller that reaches the function some other way.)
if type(hooksecurefunc) == "function" and type(ContainerFrameItemButton_OnClick) == "function" then
  hooksecurefunc("ContainerFrameItemButton_OnClick", function(button, mouseButton)
    if mouseButton ~= "RightButton" then return end
    local panel = QueueOpen()
    if not panel then return end
    queueStats.click = queueStats.click + 1
    local bag, slot
    if type(button.GetBagID) == "function" then
      local ok, id = pcall(button.GetBagID, button)
      if ok then bag = id end
    end
    if type(button.GetID) == "function" then
      local ok, id = pcall(button.GetID, button)
      if ok then slot = id end
    end
    TryEnqueue(panel, bag, slot)
  end)
end

if type(hooksecurefunc) == "function" and type(C_Container) == "table"
   and type(C_Container.UseContainerItem) == "function" then
  hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
    local panel = QueueOpen()
    if not panel then return end
    queueStats.use = queueStats.use + 1
    TryEnqueue(panel, bag, slot)
  end)
end

-- For the report: which ways in have fired this session, and the queue now.
function ST.Diagnose()
  local panel = ActivePanel()
  local waiting = (panel and panel._queue) and #panel._queue or 0
  return string.format("attach queue: click %d | use %d | refused %d | queued %d | waiting %d",
    queueStats.click, queueStats.use, queueStats.refused, queueStats.queued, waiting)
end

-- The way in, second route, and the one that holds when the first does not:
-- the client's refusal itself. A bag addon that captured UseContainerItem
-- into a local at load never passes through the hook above, but the
-- "cannot attach more than 12 items" error the client answers with fires
-- for everyone, and the item it refused is the one under the cursor -- the
-- click has only just happened. Read off whichever bag button is there:
-- the container template's GetBagID/GetID pair first, then the field names
-- the other bag addons use, and only for something that is an item button.
local function BagSlotUnderCursor()
  local frames
  if type(GetMouseFoci) == "function" then
    local ok, list = pcall(GetMouseFoci)
    if ok and type(list) == "table" then frames = list end
  elseif type(GetMouseFocus) == "function" then
    local ok, focus = pcall(GetMouseFocus)
    if ok and focus then frames = { focus } end
  end
  if not frames then return nil end

  -- The frame with focus can be a child laid over the button -- a cooldown,
  -- a quality border, an overlay of some bag addon's -- so each focus frame
  -- is walked up a few parents until something that is an item button
  -- turns up.
  local candidates = {}
  for i = 1, #frames do
    local f = frames[i]
    local depth = 0
    while type(f) == "table" and depth < 4 do
      candidates[#candidates + 1] = f
      f = type(f.GetParent) == "function" and f:GetParent() or nil
      depth = depth + 1
    end
  end

  for i = 1, #candidates do
    local f = candidates[i]
    if type(f) == "table" and type(f.IsObjectType) == "function" then
      local isItemButton = f:IsObjectType("ItemButton") or f.icon ~= nil or f.Icon ~= nil
      if isItemButton then
        local bag, slot
        if type(f.GetBagID) == "function" then
          local ok, id = pcall(f.GetBagID, f)
          if ok and type(id) == "number" then bag = id end
        end
        if bag == nil and type(f.bagID) == "number" then bag = f.bagID end
        if bag == nil and type(f.GetParent) == "function" then
          local parent = f:GetParent()
          local ok, id = pcall(function() return parent:GetID() end)
          if ok and type(id) == "number" then bag = id end
        end
        if type(f.slotID) == "number" then slot = f.slotID end
        if slot == nil and type(f.GetID) == "function" then
          local ok, id = pcall(f.GetID, f)
          if ok and type(id) == "number" then slot = id end
        end
        if type(bag) == "number" and type(slot) == "number" and slot > 0 then
          return bag, slot
        end
      end
    end
  end
  return nil
end

-- UI_ERROR_MESSAGE, while this tab is showing. Every guard the hook applies,
-- plus one the hook does not need: the error has to be answered from a
-- state in which the only thing a right-click on a bag item can be refused
-- FOR is the slot count. Every slot full, no send in flight, no C.O.D.
-- armed, and an unlocked item under the cursor -- that is the state, and
-- the item is queued. The message text is deliberately not matched: its
-- global is not published, and a state test is honest in every locale.
local function OnAttachRefused()
  local panel = QueueOpen()
  if not panel then return end
  queueStats.refused = queueStats.refused + 1
  local bag, slot = BagSlotUnderCursor()
  if not bag then return end
  TryEnqueue(panel, bag, slot)
end
ST.OnAttachRefused = OnAttachRefused

-------------------------------------------------------------
-- 19. Draft reset
--
-- Called by the shell when the mailbox opens and again when it closes.
-------------------------------------------------------------

-- An unsent draft survives walking away from the mailbox.
--
-- The three text fields are kept aside on close and put back on the next
-- open, for the session only: a mis-click on the close button, a mob, a
-- guildmate's summon -- none of them should cost a half-written mail. Only
-- text: the server drops attachments and money the moment the mailbox
-- closes, and pretending otherwise would put back a draft that no longer
-- says what it did. Never across a successful send (the fields are already
-- empty by then) and never across a reload.
local function StashDraft(panel)
  local to, subject, body = FieldText(panel.ToBox), FieldText(panel.SubjectBox), FieldText(panel.BodyBox)
  if to == "" and subject == "" and body == "" then
    panel._draftStash = nil
    return
  end
  panel._draftStash = { to = to, subject = subject, body = body }
end

local function RestoreDraft(panel)
  local stash = panel._draftStash
  panel._draftStash = nil
  if not stash then return end
  if stash.to ~= "" then ST.SetRecipient(panel, stash.to) end
  panel.SubjectBox:SetText(stash.subject)
  panel.SubjectBox:SetCursorPosition(0)
  panel.BodyBox:SetText(stash.body)
  panel.BodyBox:SetCursorPosition(0)
end

-- `reason` is "open" or "close" (see Core/MailboxUI.lua's ResetDraft); a
-- caller that says neither gets a plain reset with nothing kept.
function ST.Reset(panel, reason)
  if not panel then return end

  -- Never leave the Send button stuck disabled across a mailbox cycle. The
  -- draft itself is not touched here; ClearDraftFields below does that.
  AbandonPendingSend(panel)
  ClearSendMailMoneyState()
  if reason == "close" then StashDraft(panel) end
  ClearDraftFields(panel)
  if reason == "open" then RestoreDraft(panel) end
  -- The attachment queue does not survive the mailbox: its items are still in
  -- the bags, and a queue that reappeared at the next mailbox would be a
  -- surprise waiting to attach itself.
  panel._queue = nil
  if RefreshQueueLabel then RefreshQueueLabel(panel) end

  if panel.SuggestFrame then panel.SuggestFrame:Hide() end
  if panel.ContactPicker then panel.ContactPicker:Hide() end

  -- A blank draft has nothing that does not fit, so a session cannot inherit
  -- the previous one's accepted overflow. (The extension itself is given back by
  -- the shell, which is the one place that owns the window's height.)
  panel._elasticSlack = 0

  -- Synchronous, not coalesced: a reset is what the first paint of the tab is
  -- built on.
  ST.RefreshAttachmentSlots(panel)
  ST.UpdateSendCost(panel)
  ST.UpdateSendGuidance(panel)
end

-------------------------------------------------------------
-- 20. Build
--
-- Top to bottom: recipient label + field, the category bar, subject, the
-- message body (which absorbs the remaining height), the attachment area, the
-- money row, and the Send button pinned to the bottom with its guidance line
-- immediately above it.
--
-- The bottom bands are built before the body so the body's bottom can anchor to
-- them.
-------------------------------------------------------------

local function BuildRecipientField(panel)
  local label = CreateFieldLabel(panel, panel, "TOPLEFT", M.inset, -M.inset, L["LABEL_RECIPIENT"])
  panel.ToWrap, panel.ToBox = CreateFieldRow(panel, label, false)
  -- Longest legitimate recipient is a 12-character name plus a hyphenated
  -- realm; 64 clears every real case while stopping an accidental paste from
  -- composing an address the server can only answer with a generic failure.
  panel.ToBox:SetMaxLetters(64)

  -- A doorway to the recipient manager at the field's right edge: the window
  -- where this field's suggestions are curated, one click from where
  -- recipients are typed instead of a trip through the options panel.
  -- An inline segment at the field's right end, not a floating button: the
  -- field's own top, bottom and right edges enclose it, and a hairline on
  -- its left is the only chrome it brings. Untagged on purpose, like the
  -- window cog -- the host skins' button repaint fades a tagged button's
  -- own textures, and this one is nothing but textures.
  local manage = CreateFrame("Button", nil, panel.ToWrap)
  manage:SetPoint("TOPRIGHT", panel.ToWrap, "TOPRIGHT", -1, -1)
  manage:SetPoint("BOTTOMRIGHT", panel.ToWrap, "BOTTOMRIGHT", -1, 1)
  manage:SetWidth(24)
  manage:SetFrameLevel(panel.ToWrap:GetFrameLevel() + 5)

  local divider = manage:CreateTexture(nil, "BORDER")
  divider:SetWidth(1)
  divider:SetPoint("TOPLEFT", manage, "TOPLEFT", 0, 0)
  divider:SetPoint("BOTTOMLEFT", manage, "BOTTOMLEFT", 0, 0)
  divider:SetColorTexture(1, 1, 1, 0.12)

  local hoverWash = manage:CreateTexture(nil, "BACKGROUND")
  hoverWash:SetPoint("TOPLEFT", manage, "TOPLEFT", 1, 0)
  hoverWash:SetPoint("BOTTOMRIGHT", manage, "BOTTOMRIGHT", 0, 0)
  hoverWash:SetColorTexture(1, 1, 1, 0)

  local art = manage:CreateTexture(nil, "ARTWORK")
  art:SetSize(16, 16)
  art:SetPoint("CENTER", manage, "CENTER", 0, 0)
  art:SetTexture("Interface\\AddOns\\Postbox\\Media\\minimap-bundleclean.tga")

  -- Typed text stops short of the segment instead of running under it.
  panel.ToBox:SetTextInsets(0, 26, 0, 0)
  manage:SetScript("OnEnter", function(self)
    hoverWash:SetColorTexture(1, 1, 1, 0.07)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["RM_OPT_BUTTON"])
    GameTooltip:AddLine(L["RM_OPT_BUTTON_DESC"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  manage:SetScript("OnLeave", function()
    hoverWash:SetColorTexture(1, 1, 1, 0)
    GameTooltip:Hide()
  end)
  manage:SetScript("OnClick", function()
    local RM = ns.RecipientManager
    if RM and type(RM.Toggle) == "function" then
      RM.Toggle()
    else
      -- Same answer the /postbox recipients path gives: a doorway that does
      -- nothing at all reads as broken.
      ns.Print(L["RM_NOT_AVAILABLE"])
    end
  end)
  panel.ManageRecipients = manage
end

local function BuildContactBar(panel)
  local bar = CreateFrame("Frame", nil, panel)
  bar:SetHeight(BAR_H)
  bar:SetPoint("TOPLEFT", panel.ToWrap, "BOTTOMLEFT", 0, -BAR_GAP)
  bar:SetPoint("RIGHT", panel.ToWrap, "RIGHT", 0, 0)
  panel.ContactBar = bar

  -- Every category button, for the state refresh...
  panel.ContactButtons = {}
  -- ...and just the ones sharing the tiled middle band.
  panel.ContactTiles = {}

  -- One line, and it is the whole of the bar's plating: ring, fill, bevel,
  -- hover wash, caption font and every state colour come from the theme's
  -- control plate at its `tile` variant. The height comes with it (M.tileHeight,
  -- which is what BAR_H is), so the bar and its tiles cannot disagree.
  local function CreateBarButton(catId)
    local b = Theme.CreatePlate(bar, "tile")
    b._catId = catId
    return b
  end

  -- The plate already owns a centred, unwrapped, registered font string; this
  -- only fills it in and remembers the untruncated text for FitTileLabel.
  local function AddTileLabel(b, text)
    b._label = text
    b:SetText(text)
  end

  -- The star's glyph. Positioned by LayoutFavoriteGroup, which is why no anchor
  -- is set here: the star and its count are laid out as one centred group and
  -- the group moves whenever the count's width changes.
  local function AddIcon(b)
    b.Icon = b:CreateTexture(nil, "ARTWORK")
    b.Icon:SetSize(BAR_ICON_SIZE, BAR_ICON_SIZE)
    return b.Icon
  end

  -- `tooltip` is wanted where the label is not on screen to read. A tile whose
  -- own label had to be truncated gets one too.
  --
  -- SetScript, not HookScript, and therefore Theme.SetPlateHover by hand:
  -- replacing the plate's own OnEnter/OnLeave is what would otherwise leave a
  -- tile that never repaints on hover again, silently. That repaint restores
  -- the caption's live tone, so an empty category has to say so again straight
  -- after it -- the same order the manager's hooks run in.
  local function WireBarButton(b, catId, tooltip)
    b:SetScript("OnEnter", function(self)
      Theme.SetPlateHover(self, true)
      TintEmptyCaption(self)
      local title = tooltip or self.__pbOverflowText
      if title then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title)
        GameTooltip:Show()
        self._tipShown = true
      end
    end)
    b:SetScript("OnLeave", function(self)
      Theme.SetPlateHover(self, false)
      TintEmptyCaption(self)
      if self._tipShown then
        GameTooltip:Hide()
        self._tipShown = nil
      end
    end)
    b:SetScript("OnClick", function() OpenContactMenu(panel, catId) end)
    StyleBarButton(b)
  end

  local categories = {
    { id = "recent",  label = L["CONTACT_RECENT"] },
    { id = "alts",    label = L["CONTACT_ALTS"] },
    { id = "friends", label = L["CONTACT_FRIENDS"] },
    { id = "guild",   label = L["CONTACT_GUILD"] },
  }
  for i = 1, #categories do
    local cat = categories[i]
    local b = CreateBarButton(cat.id)
    AddTileLabel(b, cat.label)
    WireBarButton(b, cat.id)
    panel.ContactTiles[#panel.ContactTiles + 1] = b
    panel.ContactButtons[#panel.ContactButtons + 1] = b
  end

  -- All is the fifth TILE, and it wears the word rather than a glyph.
  --
  -- It used to probe four candidate atlases for a group/roster glyph and fall
  -- back to the word only where none of them existed, which bought the four
  -- named categories a little width and cost the bar its uniformity: the
  -- recipient manager's identical row of filters says "All" in words, so the
  -- same category was a picture in one window and a word in the other, and
  -- which one you got depended on the client build. A category bar whose
  -- members are not drawn alike is a bar the eye has to read twice.
  --
  -- The width is affordable: five tiles plus the star come to ~85px each at the
  -- minimum window, and "All" is the shortest label in every locale Postbox
  -- ships (Tous / Alle / Todos / Все), so it is the tile with the most room to
  -- spare rather than the least.
  --
  -- The label is the manager's own key, so the two bars cannot drift apart.
  local allButton = CreateBarButton("all")
  AddTileLabel(allButton, L["RM_FILTER_ALL"])
  WireBarButton(allButton, "all")
  panel.ContactTiles[#panel.ContactTiles + 1] = allButton
  panel.ContactButtons[#panel.ContactButtons + 1] = allButton
  panel.AllButton = allButton

  -- Favourites. Sized to its own content rather than taking a sixth equal share:
  -- six word tiles would take each from ~102px to ~85px at the default window
  -- width, and this is the one whose meaning a glyph carries alone.
  local star = CreateBarButton("favorites")
  star._isStar = true
  star:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)

  -- The empty state's own position and width, so the glyph and the count that
  -- hangs off it are anchored from the moment they exist. LayoutFavoriteGroup
  -- owns both from here on and runs below, in the first RefreshContactBar,
  -- before any of this is on screen.
  local starIcon = AddIcon(star)
  star:SetWidth(BAR_ICON_W)
  starIcon:SetPoint("LEFT", star, "LEFT", BAR_ICON_PAD, 0)
  -- RefreshContactBar re-picks the filled/hollow art from the live state; this
  -- is only the initial draw.
  ApplyFavoriteIcon(starIcon, false)

  -- Gold, and only ever on screen when there is something to count. No fixed
  -- width and no wrap: the string sizes itself and the group is measured from
  -- it, which is the combination that cannot clip. It rides on the glyph, so
  -- moving the glyph moves the pair.
  star.Count = Theme.CreateText(star, "bodySmall")
  star.Count:SetPoint("LEFT", starIcon, "RIGHT", BAR_COUNT_GAP, 0)
  star.Count:SetJustifyH("LEFT")
  star.Count:SetWordWrap(false)
  Theme.SetColor(star.Count, "accent")
  star.Count:Hide()

  star:SetScript("OnEnter", function(self)
    Theme.SetPlateHover(self, true)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["CONTACT_FAVORITES"])
    local count = self._favoriteCount or 0
    if count > 0 then
      GameTooltip:AddLine(L("CONTACT_FAV_COUNT", count), 1, 1, 1)
      GameTooltip:AddLine(L["CONTACT_FAV_OPEN"], 0.75, 0.75, 0.75, true)
    else
      -- Says what the empty state is, then how to leave it. Both are needed:
      -- "no favourites" alone is a dead end.
      GameTooltip:AddLine(L["CONTACT_FAV_NONE"], 1, 1, 1)
      GameTooltip:AddLine(FavHintText(), 0.75, 0.75, 0.75, true)
      GameTooltip:AddLine(L["CONTACT_FAV_MANAGER_HINT"], 0.75, 0.75, 0.75, true)
    end
    GameTooltip:Show()
  end)
  star:SetScript("OnLeave", function(self)
    Theme.SetPlateHover(self, false)
    GameTooltip:Hide()
  end)
  -- Opens even with nothing favourited. A well-written empty state teaches how
  -- to favourite someone; a button that declines to respond teaches that it is
  -- broken.
  star:SetScript("OnClick", function() OpenContactMenu(panel, "favorites") end)
  panel.FavoriteButton = star

  -- Synchronously, at build. The size hook is for genuine resizes only; nothing
  -- on this screen is positioned by a deferred callback.
  bar:SetScript("OnSizeChanged", function() LayoutContactBar(panel) end)
  LayoutContactBar(panel)
  RefreshContactBar(panel)
end

local function BuildAttachmentArea(panel)
  local area = CreateFrame("Frame", nil, panel)
  area:SetPoint("LEFT", panel, "LEFT", M.inset, 0)
  area:SetPoint("RIGHT", panel, "RIGHT", -M.inset, 0)
  area:SetPoint("BOTTOM", panel, "BOTTOM", 0, BottomBands())
  area:SetHeight(ItemAreaHeight(1))   -- one row; grows on refresh
  panel.ItemArea = area
  panel._attachRows = 1

  local label = Theme.CreateText(area, "label")
  label:SetPoint("TOPLEFT", area, "TOPLEFT", M.inset, -M.tightGap)
  label:SetHeight(LabelHeight())
  label:SetText(L["LABEL_ATTACHMENTS"])

  -- The attachment queue's count (section 18a), to the right of the label:
  -- "8 more queued", the items themselves in its tooltip, and a click to
  -- forget them. Hidden while nothing is queued, which is nearly always.
  local queueButton = CreateFrame("Button", nil, area)
  queueButton:SetPoint("LEFT", label, "RIGHT", M.gap, 0)
  queueButton:SetHeight(LabelHeight())
  queueButton:SetWidth(1)
  queueButton.Text = Theme.CreateText(queueButton, "secondary")
  queueButton.Text:SetPoint("LEFT", queueButton, "LEFT", 0, 0)
  queueButton.Text:SetJustifyH("LEFT")
  queueButton.Text:SetWordWrap(false)
  queueButton:SetScript("OnEnter", function(self)
    local queue = panel._queue
    if not queue or #queue == 0 then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["QUEUE_TIP_TITLE"], 1, 1, 1)
    local shown = math.min(#queue, SEND_SLOT_COUNT)
    for i = 1, shown do
      local entry = queue[i]
      local line = entry.link or "?"
      if (entry.count or 1) > 1 then line = line .. " x" .. entry.count end
      GameTooltip:AddLine(line, 1, 1, 1)
    end
    if #queue > shown then
      GameTooltip:AddLine(L("MEMORY_WAITING_MORE", #queue - shown), 0.75, 0.75, 0.75)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["QUEUE_TIP_HOW"], 0.75, 0.75, 0.75, true)
    GameTooltip:AddLine(L["QUEUE_TIP_CLEAR"], 0.75, 0.75, 0.75, true)
    GameTooltip:Show()
  end)
  queueButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  queueButton:SetScript("OnClick", function()
    panel._queue = nil
    GameTooltip:Hide()
    if RefreshQueueLabel then RefreshQueueLabel(panel) end
  end)
  queueButton:Hide()
  panel.QueueLabel = queueButton

  local function SlotEnter(self)
    if not self.itemLink then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(self.itemLink)
    GameTooltip:Show()
  end

  local function SlotLeave() GameTooltip:Hide() end

  local function AfterSlotChange()
    Invalidate(panel, "slots")
    Invalidate(panel, "bags")
    Invalidate(panel, "cost")
  end

  local function SlotClick(self, button)
    if type(ClickSendMailItemButton) ~= "function" then return end
    local hasCursorItem = (type(CursorHasItem) == "function" and CursorHasItem())

    if button == "RightButton" and not hasCursorItem then
      -- Native behaviour: right-click with an empty cursor returns the attached
      -- item to the bags.
      ClickSendMailItemButton(self.slotIndex, true)
    else
      -- Left-click toggles attach/detach; right-click with a cursor item drops
      -- it into this slot.
      ClickSendMailItemButton(self.slotIndex)
    end

    AfterSlotChange()
  end

  local function SlotReceiveDrag(self)
    if type(ClickSendMailItemButton) ~= "function" then return end
    ClickSendMailItemButton(self.slotIndex)
    AfterSlotChange()
  end

  panel.ItemSlots = {}
  for i = 1, SEND_SLOT_COUNT do
    local slot = CreateAttachmentSlot(area, i)
    slot:SetScript("OnEnter", SlotEnter)
    slot:SetScript("OnLeave", SlotLeave)
    slot:SetScript("OnClick", SlotClick)
    slot:SetScript("OnReceiveDrag", SlotReceiveDrag)
    panel.ItemSlots[i] = slot
  end
end

local function BuildMoneyRow(panel)
  local row = CreateFrame("Frame", nil, panel)
  -- Tight against the attachment area above it: this stack (attachments, gold,
  -- C.O.D., postage) sits directly over the Send button and every pixel it does
  -- not need belongs to the message body.
  row:SetPoint("TOPLEFT", panel.ItemArea, "BOTTOMLEFT", 0, -M.tightGap)
  row:SetPoint("RIGHT", panel, "RIGHT", -M.inset, 0)
  row:SetHeight(MONEY_ROW_H)
  panel.GoldArea = row

  local label = Theme.CreateText(row, "label")
  label:SetPoint("LEFT", row, "LEFT", M.inset, 0)
  label:SetText(L["LABEL_GOLD_SEND"])

  local function CoinIcon(anchor, texture)
    local icon = row:CreateTexture(nil, "OVERLAY")
    icon:SetSize(M.iconSize, M.iconSize)
    icon:SetPoint("LEFT", anchor, "RIGHT", 2, 0)
    icon:SetTexture(texture)
    return icon
  end

  local goldWrap
  goldWrap, panel.GoldBox = CreateMoneyInput(row, label, 58, 7)
  local goldIcon = CoinIcon(goldWrap, "Interface\\MoneyFrame\\UI-GoldIcon")

  local silverWrap
  silverWrap, panel.SilverBox = CreateMoneyInput(row, goldIcon, 38, 2)
  local silverIcon = CoinIcon(silverWrap, "Interface\\MoneyFrame\\UI-SilverIcon")

  local copperWrap
  copperWrap, panel.CopperBox = CreateMoneyInput(row, silverIcon, 38, 2)
  local copperIcon = CoinIcon(copperWrap, "Interface\\MoneyFrame\\UI-CopperIcon")

  -- Tab walks the amount left to right, the way it is written.
  panel.GoldBox:SetScript("OnTabPressed", function() panel.SilverBox:SetFocus() end)
  panel.SilverBox:SetScript("OnTabPressed", function() panel.CopperBox:SetFocus() end)
  panel.CopperBox:SetScript("OnTabPressed", function() panel.GoldBox:SetFocus() end)

  -- The boxes are numeric-only, so any change is a real change.
  local moneyBoxes = { panel.GoldBox, panel.SilverBox, panel.CopperBox }
  for i = 1, #moneyBoxes do
    moneyBoxes[i]:HookScript("OnTextChanged", function() Invalidate(panel, "guidance") end)
  end

  -- C.O.D. toggle. Both skin tags are required: __postboxCheck is how the skins
  -- find the box and __label is how they find its caption. Without them this was
  -- the one control on the compose screen no skin styled at all.
  local cod = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
  cod:SetSize(MONEY_INPUT_H, MONEY_INPUT_H)
  cod:SetPoint("LEFT", copperIcon, "RIGHT", M.gap * 2, 0)
  cod.text = Theme.CreateText(cod, "label")
  cod.text:SetPoint("LEFT", cod, "RIGHT", 2, 0)
  cod.text:SetText(L["LABEL_COD_SHORT"])
  cod.__postboxCheck = true
  cod.__label = cod.text
  cod:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["TOOLTIP_COD_TITLE"])
    GameTooltip:AddLine(L["TOOLTIP_COD_DESC"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  cod:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Hooked rather than set: the template owns OnClick (the check sound), and
  -- replacing it to add one line would take the sound with it. Ticking C.O.D.
  -- changes what the money field MEANS, so the guidance line has to follow.
  cod:HookScript("OnClick", function() Invalidate(panel, "guidance") end)
  panel.CODCheck = cod

  -- Postage. `secondary`, never red: red in this window means an error that has
  -- already happened, and postage is not one.
  panel.SendCostLabel = Theme.CreateText(row, "secondary")
  panel.SendCostLabel:SetPoint("RIGHT", row, "RIGHT", -M.tightGap, 0)
  panel.SendCostLabel:SetText("")
end

local function BuildSendControls(panel)
  local button = (Theme.CreateButton and Theme.CreateButton(nil, panel))
    or CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  button:SetHeight(SEND_BUTTON_H)
  button:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", M.inset, M.inset)
  button:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -M.inset, M.inset)
  button:SetText(L["BTN_SEND_MAIL"])
  if Theme.StyleButton then Theme.StyleButton(button, { fontRole = "normal" }) end
  button:SetScript("OnClick", function() DoSendMail(panel) end)
  panel.FillButton = button

  -- The guidance line, immediately above the button it is about. Anchored to the
  -- button rather than to the money row so it stays with the action even if the
  -- rows above it are ever re-spaced.
  --
  -- Wrapping and vertically centred: a warning that has to say two things runs
  -- to two lines in a narrow window, and the one-line notes then still sit level
  -- in the same band instead of hanging from its top edge.
  local guidance = Theme.CreateText(panel, "secondary")
  guidance:SetPoint("BOTTOMLEFT", button, "TOPLEFT", 0, GUIDANCE_GAP)
  guidance:SetPoint("BOTTOMRIGHT", button, "TOPRIGHT", 0, GUIDANCE_GAP)
  guidance:SetHeight(GuidanceHeight())
  guidance:SetJustifyH("LEFT")
  guidance:SetJustifyV("MIDDLE")
  guidance:SetWordWrap(true)
  guidance:SetText("")
  panel.GuidanceLabel = guidance
end

-- Events this panel answers ONLY while it is on screen.
--
-- BAG_UPDATE and ITEM_LOCK_CHANGED fire for every loot, every craft and every
-- item moved in a bag, anywhere in the world. A hidden frame still receives its
-- registered events, so with these registered permanently -- as they were --
-- the Send tab spent the whole session from the first mailbox visit to logout
-- allocating a closure and a C_Timer object per event, to schedule a drain that
-- returned immediately because the panel was hidden.
--
-- Nothing is missed by not listening. OnShow re-reads the send slots, the
-- postage and the guidance outright, which is a stronger guarantee than
-- replaying the events would have been: it reads the state, not the news about
-- it. Any dirty flags left over from before the tab was hidden are drained by
-- the same pass.
--
-- MAIL_SEND_SUCCESS and MAIL_FAILED stay registered permanently and
-- deliberately: the user can switch to the collect screen while the server is
-- still working, and the draft must still be settled when they do.
--
-- The last four are the contact sources reporting in (section 15b). They are
-- the chattiest events in the list -- BN_FRIEND_INFO_CHANGED fires for every
-- presence tick of every Battle.net friend -- which is exactly why they are
-- here rather than registered for the session: off the compose tab there is no
-- list of contacts on screen for them to fill in.
local VISIBILITY_EVENTS = {
  "MAIL_SEND_INFO_UPDATE", "ITEM_LOCK_CHANGED", "BAG_UPDATE", "MAIL_SUCCESS",
  "GUILD_ROSTER_UPDATE", "FRIENDLIST_UPDATE", "BN_FRIEND_INFO_CHANGED", "BN_CONNECTED",
  -- The attachment queue's second way in (section 18a): the client refusing
  -- a thirteenth attachment. Only while this tab is showing, because that is
  -- the only time the refusal can mean anything to it.
  "UI_ERROR_MESSAGE",
}

local function InstallEvents(panel)
  panel:RegisterEvent("MAIL_SEND_SUCCESS")
  panel:RegisterEvent("MAIL_FAILED")

  panel:SetScript("OnEvent", function(self, event)
    -- The send outcome is settled BEFORE any visibility guard: the user can
    -- switch to the collect screen while the server is still working, and the
    -- draft must still be handled correctly when they do.
    if event == "MAIL_SEND_SUCCESS" then
      FinishSend("success")
    elseif event == "MAIL_FAILED" then
      FinishSend("failed")
    elseif event == "UI_ERROR_MESSAGE" then
      OnAttachRefused(self)
      return
    end

    if event == "MAIL_SEND_INFO_UPDATE" or event == "MAIL_FAILED" then
      Invalidate(self, "slots")
      Invalidate(self, "bags")
      Invalidate(self, "cost")
    elseif event == "ITEM_LOCK_CHANGED" then
      Invalidate(self, "slots")
    elseif event == "BAG_UPDATE" or event == "MAIL_SUCCESS" then
      Invalidate(self, "slots")
      Invalidate(self, "bags")
    elseif event == "GUILD_ROSTER_UPDATE" or event == "FRIENDLIST_UPDATE"
        or event == "BN_FRIEND_INFO_CHANGED" or event == "BN_CONNECTED" then
      -- A contact source answered. Marking is all that happens here: whether
      -- there is anything on screen to fill in is section 15b's question, asked
      -- once on the next frame however many of these arrive in between.
      Invalidate(self, "contacts")
    end
  end)

  panel:SetScript("OnShow", function(self)
    -- Registered before the refresh below, so anything that fires during it is
    -- still coalesced into the same drain.
    for i = 1, #VISIBILITY_EVENTS do self:RegisterEvent(VISIBILITY_EVENTS[i]) end

    ST.ActivateNativeSendMail()
    -- Drop MailRules' memos before anything asks it a question: opening the
    -- mailbox is the one moment the player's alt list or connected-realm group
    -- can have changed since they were last read.
    if ns.MailRules and type(ns.MailRules.Invalidate) == "function" then
      ns.MailRules.Invalidate()
    end
    ST.RefreshAttachmentSlots(self)
    ST.UpdateSendCost(self)
    ST.UpdateSendGuidance(self)
    -- Favourites can change while this tab is hidden (the recipient manager is
    -- its own window and can sit open beside the mailbox), and so can what any
    -- of the categories hold -- so the dimming is re-decided before the bar is
    -- repainted from it.
    RefreshCategoryEmptiness(self)
    RefreshContactBar(self)
    -- Whatever went stale while the tab was hidden, plus the bag pass.
    Invalidate(self, "bags")
  end)

  panel:SetScript("OnHide", function(self)
    for i = 1, #VISIBILITY_EVENTS do self:UnregisterEvent(VISIBILITY_EVENTS[i]) end

    CloseOtherLists(self)
    ST.ClearBagOverlays()
    ST.DeactivateNativeSendMail()
    -- Never leave C.O.D. / attached money armed on a tab the user has left. Any
    -- send sets both explicitly anyway, so this costs nothing and closes the
    -- window where an abandoned draft could influence a later mail.
    ClearSendMailMoneyState()
    -- Drop every scrap of extra window height this screen asked for -- the
    -- attachment row and the message extension both -- so the collect screen
    -- and the saved base size are not left inflated. The shell drops them too
    -- on a tab switch; this covers every other way the panel can be hidden.
    local UI = ns.MailboxUI
    if UI and UI.SetMessageExtraHeight then UI.SetMessageExtraHeight(0) end
    if UI and UI.SetAttachmentRows then UI.SetAttachmentRows(1) end
    -- The SLACK deliberately survives being hidden: it is what the user decided
    -- to scroll rather than see, and coming back to a screen they had made
    -- deliberately short must not undo that. It decays with the text on its own
    -- (section 16b), and a fresh draft clears it outright (ST.Reset).
  end)
end

function ST.Build(parent)
  local panel = CreateFrame("Frame", nil, parent)
  panel:SetAllPoints()

  BuildRecipientField(panel)
  BuildContactBar(panel)

  panel.SuggestFrame = CreateSuggestionPopup(panel)

  -- Recipient input behaviour. Suggestions are only offered for text the player
  -- typed; the guidance line follows EVERY change, including the SetText that
  -- picking a name performs -- and including the inline completion's own, which
  -- is exactly right: the guidance, the postage and the Send button all describe
  -- the name that is VISIBLE, which is the one that would be written to.
  panel.ToBox:SetScript("OnTextChanged", function(self, userInput)
    if userInput and not panel._acGuard then
      NoteRecipientEdit(panel, self)
      ScheduleSuggestions(panel)
    end
    ST.UpdateSendGuidance(panel)
  end)
  panel.ToBox:SetScript("OnTabPressed", function() RecipientTabPressed(panel) end)
  -- Two stages: cancel the completion, then -- with nothing left to cancel --
  -- the field's own Escape, which PrepareEditBox set to ClearFocus.
  panel.ToBox:SetScript("OnEscapePressed", function(self)
    if RecipientEscapePressed(panel) then return end
    self:ClearFocus()
  end)
  -- Enter is "done, next field", as it is in the client's own send frame.
  -- Whatever the box holds -- typed, completed or taken by Tab -- is the
  -- answer; moving focus drops the selection and, after its grace, the popup.
  panel.ToBox:SetScript("OnEnterPressed", function()
    if panel.SubjectBox then panel.SubjectBox:SetFocus() end
  end)
  panel.ToBox:SetScript("OnEditFocusGained", function(self)
    if self:GetText() ~= "" then self:HighlightText() end
    RefreshSuggestions(panel)
  end)
  panel.ToBox:SetScript("OnEditFocusLost", function()
    -- A short grace, so a click on a suggestion lands before the popup goes.
    local token = (panel._suggestToken or 0) + 1
    panel._suggestToken = token
    C_Timer.After(SUGGEST_GRACE, function()
      if panel._suggestToken == token then panel.SuggestFrame:Hide() end
    end)
  end)

  -- Subject
  local subjectLabel = CreateFieldLabel(panel, panel.ContactBar, "BOTTOMLEFT",
                                        0, -SUBJECT_LABEL_GAP, L["LABEL_SUBJECT"])
  panel.SubjectWrap, panel.SubjectBox = CreateFieldRow(panel, subjectLabel, false)
  -- The server's own cap (Blizzard's send frame uses the same number). Typed
  -- or pasted overflow is truncated here instead of failing the whole send
  -- with nothing but a generic error to explain it.
  panel.SubjectBox:SetMaxLetters(64)
  panel.SubjectPlaceholder = AttachPlaceholder(panel.SubjectWrap, panel.SubjectBox,
                                               L["DEFAULT_SUBJECT"], false)
  panel.SubjectBox:SetScript("OnTextChanged", function(self)
    self._placeholder:SetShown(self:GetText() == "")
  end)
  panel.SubjectBox:SetScript("OnEditFocusGained", function(self)
    if self:GetText() ~= "" then self:HighlightText() end
  end)
  panel.SubjectBox:SetScript("OnEnterPressed", function()
    if panel.BodyBox then panel.BodyBox:SetFocus() end
  end)

  -- Message label. The field itself is built after the bottom bands, because it
  -- absorbs whatever height they leave.
  panel.MessageLabel = CreateFieldLabel(panel, panel.SubjectWrap, "BOTTOMLEFT",
                                        0, -BAND_GAP, L["LABEL_MESSAGE"])

  BuildAttachmentArea(panel)
  BuildMoneyRow(panel)
  BuildSendControls(panel)

  panel.BodyWrap, panel.BodyBox = CreateFieldRow(panel, panel.MessageLabel, true)
  -- The server's body cap, same number as Blizzard's send frame.
  panel.BodyBox:SetMaxLetters(500)
  -- The body's vertical anchors belong to one function, which is also where the
  -- message box's hard minimum is enforced.
  ST.ApplyBodyBounds(panel)
  -- Every pixel a taller window adds lands in the message box, and a window that
  -- somehow got shorter than the derived floor still cannot crush it.
  --
  -- The panel fills the window, so its OnSizeChanged IS the window's resize
  -- path -- a drag on the grip, a programmatic SetSize, the extra height a
  -- second row of attachments asks for. Every list this screen can open is
  -- anchored to something that has just moved and sized to a width that has
  -- just changed, so all three are closed rather than left hanging at their
  -- old geometry. Nothing here reopens: CloseListsForResize cancels the
  -- debounced type-ahead pass as well, and re-laying the body out cannot ask
  -- for a list. See the note in CloseListsForResize about the To: box.
  panel:SetScript("OnSizeChanged", function(self)
    ST.ApplyBodyBounds(self)
    CloseListsForResize(self)
  end)
  panel.BodyPlaceholder = AttachPlaceholder(panel.BodyWrap, panel.BodyBox,
                                            L["DEFAULT_BODY"], true)
  panel.BodyBox:SetScript("OnTextChanged", function(self)
    self._placeholder:SetShown(self:GetText() == "")
    -- The message just changed shape -- a line typed, a line deleted, a paste --
    -- so ask the window for the height it now needs. Coalesced onto the next
    -- frame because the edit box has not re-measured itself yet, and because a
    -- held key must not cost a resize per repeat.
    Invalidate(panel, "body")
  end)
  panel.BodyBox:SetScript("OnEditFocusGained", function(self)
    if self:GetText() ~= "" then self:HighlightText() end
  end)

  InstallEvents(panel)

  return panel
end
