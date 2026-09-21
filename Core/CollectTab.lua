local _, ns = ...

-------------------------------------------------------------
-- Postbox :: the collect screen.
--
-- Five things live here and nothing else does:
--
--   THE VIEW SWITCH   three segments -- mail that still holds something
--                     ("Collect"), mail that is finished ("Done"), and the
--                     unfiltered inbox ("All") -- drawn as plates from the
--                     theme's control-plate tokens.
--   THE MAIL LIST     a virtualised, pooled list. WoW cannot free a frame, so
--                     rows are acquired from a pool and released by hiding
--                     them. Only the rows the viewport can show ever exist.
--   THE TOTALS BANNER earned / spent across the mails currently listed.
--   THE ACTION AREA   the category grid in the to-collect view, the bulk delete
--                     in the done view.
--   THE DETAIL VIEW   an overlay over the screen: header, metadata, body,
--                     attachment slots, action row.
--
-- Two rules govern the whole file.
--
--   NO MAIL COMMANDS. Every mail command is a round trip and the server handles
--   one at a time; ns.MailService owns the handshake, the descending-index
--   invariant, take verification and the timeout that stops a run instead of
--   advancing past it. Nothing here calls TakeInboxItem, TakeInboxMoney,
--   DeleteInboxItem, ReturnInboxItem, AutoLootMailItem or CheckInbox. What
--   stays here is what a status code cannot carry: which words the player sees,
--   which confirmation to raise, and the bookkeeping a run needs to report
--   honestly at the end.
--
--   NO COLOUR, FONT OR METRIC OF ITS OWN. Core/Theme.lua is the design system;
--   every surface, text role, gap and measured width comes from it. Anything
--   whose caption comes from a locale is sized from the rendered string, never
--   from a constant tuned to English.
--
-- That now holds without exception. GetInboxText was the last mail API called
-- from this file -- the detail view needed it for a mail's body -- and it was
-- the one that least deserved an exception: it reads like a getter and is a
-- command that marks the mail read. It is ns.MailService.FetchMailBody now, and
-- the rule above has no "except".
-------------------------------------------------------------

ns.CollectTab = ns.CollectTab or {}
local CT = ns.CollectTab

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local format, concat = string.format, table.concat

-- Cross-module dependencies are resolved at call time, never at file scope, so
-- a TOC reorder degrades instead of erroring at load.
local function Mail()    return ns.MailService end
local function Helpers() return ns.Helpers end
local function Labels()  return ns.CATEGORY_LABELS or {} end
local function L()       return ns.L end
local function Th()      return ns.Theme end

-- What a row says in place of "Auction House" for each auction outcome, and
-- the palette role it says it in: a sale is good news, a win is neutral,
-- an expiry wants a look, a cancellation is the player's own doing.
local AUCTION_OUTCOME = {
  sold     = { key = "ROW_AH_SOLD",     role = "positive" },
  bought   = { key = "ROW_AH_BOUGHT",   role = "accent" },
  expired  = { key = "ROW_AH_EXPIRED",  role = "warning" },
  canceled = { key = "ROW_AH_CANCELED", role = "textSecondary" },
}

-- The template's scroll bar, put where a modern one goes: pinned inside the
-- container's right edge with the rows ending just beside it, instead of
-- hanging six pixels outside the scroll frame with a hand's width of empty
-- track between it and the content. And hidden when there is nothing to
-- scroll -- the template's own scrollBarHideable flag, honoured by its
-- OnScrollRangeChanged, so no handler of ours is involved. Both host skins
-- and Postbox Modern flatten the bar's art; this only decides where it is.
local function PinScrollBar(scroll, container)
  if not scroll then return end
  scroll.scrollBarHideable = 1
  Th().SlimScrollBar(scroll, container)
end

-------------------------------------------------------------
-- Constants
--
-- Hoisted to module scope: the layout code runs on every resize and the row
-- binder runs once per visible row per refresh, so neither rebuilds a table.
-------------------------------------------------------------

-- ONE TAXONOMY, AND IT IS ABOUT CONTENT, NEVER ABOUT THE READ FLAG.
--
-- A mail is either still holding something -- money, attachments, or simply the
-- fact that it has not been opened -- or it is finished with. That is the split
-- the first two segments make and the split the tab counts count.
-- Mail().IsReadPersistent is the single predicate behind both.
--
-- The screen used to say this two ways at once: the segments read "Mail" and
-- "Read", which sound like a read/unread split, while the summary above them
-- counted the read FLAG. Both numbers were correct and they disagreed on screen,
-- which is the worst of both. The read flag survives in exactly two places now,
-- and neither is a headline: the per-row dot, and the detail view's metadata.
--
-- The third segment applies no filter at all. It is not a third KIND of mail --
-- it is the union of the other two, in the same order -- so nothing in this file
-- branches on "the all view" to decide what a mail IS. Everything a row's
-- appearance or behaviour depends on comes from that row's own verdict
-- (`row.mailDone`), which is why a done mail carries its delete control and
-- opens on any click whether it is being shown under "Done" or under "All".
local VIEW_COLLECT, VIEW_DONE, VIEW_ALL = "collect", "done", "all"

-- The category vocabulary is the domain's; the order is presentation. "all"
-- leads and spans the full width -- deliberate hierarchy, not an accident.
local CATEGORY_ORDER = { "all", "expired", "sold", "canceled", "bought", "other" }
local GRID_COLUMNS = 3

-- Tab counts above this render as "99+" so a three-digit count cannot push a
-- segment past the width its neighbour needs.
local COUNT_CAP = 99

-- The window's persisted minimum is 480 wide; the shell's content inset takes
-- ~20 of it. Used only as the fallback when a container's anchored width still
-- reads zero -- during the very first layout pass, before the window has been
-- sized. Laying out against this is what stops the grid visibly jumping into
-- place a frame after the window opens.
local FALLBACK_PANEL_WIDTH = 460

-- Mail row geometry. The stride is what the virtualiser divides by, so it is
-- the row plus its separating gap and nothing else.
--
-- Two sets of sizes, one per layout: the standard two-line row, and the compact
-- single-line row the `compactRows` option asks for. Everything here is a SIZE
-- and never a position -- ApplyRowMode is the only place that decides which set
-- a row is wearing, and RowMetrics is the only place that decides how tall it
-- makes the row.
local ROW_GAP = 2
local ROW_INDICATOR = 8
local ROW_ICON = 28
local ROW_ICON_COMPACT = 18
local ROW_DELETE = 20
local ROW_DELETE_COMPACT = 16
-- The stuck marker. Small on purpose: it appears on the handful of rows the
-- server refused and must read as an annotation on the row, not as a control.
local ROW_WARNING = 14
local ROW_WARNING_COMPACT = 11

-- The compact row's height, and NOT a fraction of Theme.Metrics.rowHeight: this
-- is the height at which one line of the small font sits centred beside an 18px
-- icon, and a fraction of a metric someone later retunes would quietly stop
-- being that. It is a hair under 60% of the standard 44.
local COMPACT_ROW_HEIGHT = 26

-- The most of a compact row's text area the inline meta may claim. The sender
-- and the subject are what a mailbox is scanned by; the gold and the expiry
-- annotate them, and an annotation may not crowd out the thing it annotates.
local COMPACT_META_SHARE = 0.45

-- The meta line's separator, and the compact strip's. The strip is narrow and
-- every part in it carries its own label or its own colour, so it needs no
-- rules between them -- only enough air that two numbers do not read as one.
local ROW_META_JOIN = "  |  "
local COMPACT_META_JOIN = "  "

-- Category grid: the full-width primary, then two rows of three.
-- The primary matches the Send tab's Send button exactly: the two tabs'
-- bottom-most control is the same control in both, and reads as such.
local GRID_PRIMARY_HEIGHT = 28
local GRID_BUTTON_HEIGHT  = 26

-- The sender column of a mail row, as a fraction of the text area with a floor
-- and a ceiling. A share rather than a constant because a 480px window and a
-- 750px one want different splits, and clamped because neither extreme reads.
local SENDER_SHARE = 0.34
local SENDER_MIN, SENDER_MAX = 70, 170

-- The addon's own white tile: a UI pack's loose-file overrides can replace
-- art at Blizzard paths, and a structural fill must survive that (see
-- Lib/UI/Theme.lua). Glyph art like the empty-slot backpack stays native on
-- purpose -- it SHOULD follow whatever the player's base UI looks like.
local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"
local EMPTY_SLOT_ART = "Interface\\PaperDoll\\UI-Backpack-EmptySlot"

-- Art, in preference order, PROBED and never assumed -- SetAtlas with a name the
-- client does not have does not error, it clears the texture, which would leave
-- a silent hole exactly where a control or a warning should be. Same probe
-- Core/RecipientManager.lua uses for the favourite star.
--
-- Each family falls back to a bare character in the same tone: a glyph that
-- renders on every client, in every locale, and needs no artwork at all.
--
-- The delete control used to be Interface\Buttons\UI-GroupLoot-Pass-Up drawn at
-- the control's full size. That file is a group-loot BUTTON, not a glyph: its
-- art fills its own square edge to edge, so at 20px it read as a solid red tile
-- rather than as a small X -- and it was the only red object on an otherwise
-- neutral row. A close/remove atlas is a glyph on transparency, which is what
-- this control wanted all along.
local DELETE_ATLASES = { "uitools-icon-close", "transmog-icon-remove", "common-icon-redx" }
local DELETE_GLYPH = "\195\151"   -- U+00D7 MULTIPLICATION SIGN
-- The refusal marker's candidates are Theme.AtlasSets.warning, NOT a list of
-- this file's own: the mailbox memory draws the same marker, and a copy here
-- would let the two screens land on different art on a client that has only the
-- second choice. Delete is this screen's alone and stays local.
local WARNING_GLYPH = "!"

-- The glyph is inset inside the control on every side. THE CONTROL IS THE HIT
-- AREA and the glyph is what the hit area contains: shrinking the art is what
-- turns a tile into a mark, and doing it by shrinking the BUTTON would have made
-- a 20px target into a 14px one.
local DELETE_GLYPH_INSET = 3

local function Clear(t)
  for i = #t, 1, -1 do t[i] = nil end
end

-- candidates -> the first name this client actually has, or nil. Theme's, and
-- memoised per NAME there, so a family shared with another screen is probed once
-- for the session and both screens land on the same art. Reached through Th()
-- like every other theme call in this file, so nothing here depends on load
-- order.
local function ProbeAtlas(candidates)
  return Th().FirstAtlas(candidates)
end

-------------------------------------------------------------
-- Talking to the shell
--
-- The screen never reaches into the window's internals. It asks the shell to
-- render a status line and, failing that, writes the one named field the skin
-- contract already guarantees exists. It publishes its own run state instead of
-- parking it on the shell's shared table, which is what used to couple the two
-- in both directions.
-------------------------------------------------------------

-- The shell layers the status line: an activity is transient and belongs to a
-- run in progress, an outcome is sticky and is what the run ended up doing.
-- Keeping them apart is what stops an unrelated inbox update overwriting
-- "Incomplete: 3 left" a fraction of a second after it appears. `tone` is a
-- palette token.
local function WriteStatus(setter, text, tone)
  local UI = ns.MailboxUI
  if not UI then return end
  if type(UI[setter]) == "function" then
    UI[setter](text, tone)
    return
  end
  -- No layered status on this shell: write the one named field the skin
  -- contract guarantees, and let it take the text over.
  local label = UI._frame and UI._frame.Status
  if label and type(label.SetText) == "function" then label:SetText(text) end
end

local function StatusActivity(text, tone)
  WriteStatus("SetStatusActivity", text, tone)
end

local function StatusOutcome(text, tone)
  WriteStatus("SetStatusOutcome", text, tone)
end

-- The shell's idle line reports stuck mail and nothing else, and a take the
-- server refused may change nothing in the inbox at all -- so there is no
-- MAIL_INBOX_UPDATE to recompute it on. The two single-mail paths therefore say
-- so directly. A run does not: its outcome owns the status line for the rest of
-- the visit, and it asks the domain for an inbox refresh when it ends.
--
-- This is not new event traffic. It is the same recomputation the shell already
-- runs on every inbox update, asked for at the one moment its answer changed.
local function RefreshIdleSummary()
  local UI = ns.MailboxUI
  if UI and type(UI.UpdateStatusSummary) == "function" then UI.UpdateStatusSummary() end
end

-- The mailbox interaction. ns.MailService owns the question -- it is the module
-- that gates every command on the answer, and a second copy here could disagree
-- with the one that actually decides. This is the same "open unless both the
-- client and the shell say closed" rule, reached through the service.
local function MailboxOpen()
  local service = Mail()
  if service and type(service.IsMailboxOpen) == "function" then
    return service.IsMailboxOpen() and true or false
  end
  local UI = ns.MailboxUI
  if UI and type(UI.IsMailboxOpen) == "function" then return UI.IsMailboxOpen() end
  if UI and UI._state then return UI._state.mailboxOpen == true end
  return true
end

-- "The mailbox closed" is the one outcome that used to be swallowed everywhere
-- it could occur: the service returns "closed", the caller returned, and the
-- button appeared to do nothing at all. Every path that can end that way now
-- says so on the status line, which also means a client that reported "closed"
-- wrongly would be visibly wrong instead of silently broken.
local function StatusMailboxClosed()
  StatusOutcome(L()["STATUS_STOPPED"], "warning")
end

-- The client's own word for "delete", already localised for every locale it
-- ships. The addon key is a fallback for a client that somehow lacks it.
local function DeleteLabel()
  if type(DELETE) == "string" and DELETE ~= "" then return DELETE end
  return L()["BTN_DELETE_ALL_DONE"]
end

local function ShowTabCounts()
  local UI = ns.MailboxUI
  -- Default on when the option plumbing has not loaded yet.
  if not UI or type(UI.GetOption) ~= "function" then return true end
  return UI.GetOption("showTabCounts") and true or false
end

-- The third segment. Collect and Done are the two halves of the inbox and
-- always exist; All is their union, which some players read as one screen
-- too many. Default on -- it is what the screen has always offered.
local function ShowAllSegment()
  local UI = ns.MailboxUI
  if not UI or type(UI.GetOption) ~= "function" then return true end
  return UI.GetOption("showAllTab") and true or false
end

-- The five category sweeps under the full-width Collect button. Default on,
-- for the same reason as the All segment; off gives the list their two rows.
local function ShowCategoryButtons()
  local UI = ns.MailboxUI
  if not UI or type(UI.GetOption) ~= "function" then return true end
  return UI.GetOption("showCategoryButtons") and true or false
end

-- Default OFF when the option plumbing has not loaded yet: a plain click that
-- collects is the mapping every other part of this screen was written around,
-- and the destructive-looking surprise is the other way round.
local function PreviewOnClick()
  local UI = ns.MailboxUI
  if not UI or type(UI.GetOption) ~= "function" then return false end
  return UI.GetOption("previewOnClick") and true or false
end

-- Default OFF when the option plumbing has not loaded yet: the standard row is
-- what every other measurement in this file was drawn around.
local function CompactRows()
  local UI = ns.MailboxUI
  if not UI or type(UI.GetOption) ~= "function" then return false end
  return UI.GetOption("compactRows") and true or false
end

-- THE answer to "how tall is a mail row", and the only one.
--
-- The row builder, the binder's column widths, the virtualiser's visible-count
-- and offset maths, the scroll child's height and the option toggle's
-- scroll-position preservation all take the mode, the height and the stride
-- from here in one call. A second copy of that arithmetic anywhere would be a
-- copy that can disagree by a pixel or two -- which is invisible at the top of
-- the list and, a screenful down, is rows creeping out of the viewport the
-- scroller thinks it filled.
local function RowMetrics()
  local compact = CompactRows()
  local height = compact and COMPACT_ROW_HEIGHT or Th().Metrics.rowHeight
  return compact, height, height + ROW_GAP
end

-------------------------------------------------------------
-- The screen's floor
--
-- A mailbox that can only show two rows is a peephole, not a list: every answer
-- to "what is in here" costs a scroll, and the scroll bar is taller than the
-- thing it scrolls. So the list claims a minimum of its own, the shell adds the
-- fixed furniture and the window's own chrome to it (Core/MailboxUI.lua's
-- MinWindowHeight takes the taller of this and the compose screen's demand), and
-- the window cannot be dragged -- or restored from saved variables -- below it.
--
-- THE MINIMUM IS ONE NUMBER FOR BOTH ROW LAYOUTS, and that is the point.
-- `compactRows` is a display preference; a display preference that resizes the
-- window is a preference that fights the size the player chose, and toggling it
-- twice would have to land back on the same window or it is worse still. So the
-- floor satisfies BOTH layouts at once and RowMetrics is deliberately not
-- consulted here: five compact rows and three standard ones, whichever of the
-- two wants more.
--
-- Five and three are the same judgement expressed in the two densities -- enough
-- rows that scrolling continues something rather than being the only way to see
-- anything -- and the two happen to land within a few pixels of each other. That
-- near-coincidence is a property of today's row heights and nothing to rely on,
-- which is why the max is taken from the LIVE metrics: retune either height and
-- both guarantees still hold, rather than one of them silently lapsing.
local COMPACT_MIN_ROWS  = 5
local STANDARD_MIN_ROWS = 3

-- N rows occupy N heights AND the N-1 gaps between them -- the same arithmetic
-- the virtualiser positions them with. N * height alone leaves the last row
-- clipped by exactly the gaps it forgot, which is the difference between five
-- rows fitting and four rows plus a sliver.
local function RowsHeight(rows, height)
  return rows * height + (rows - 1) * ROW_GAP
end

local function ListMinHeight()
  return max(RowsHeight(COMPACT_MIN_ROWS, COMPACT_ROW_HEIGHT),
             RowsHeight(STANDARD_MIN_ROWS, Th().Metrics.rowHeight))
end

-- THE PANEL'S FLOOR. Frozen: Core/MailboxUI.lua adds the window's chrome to this
-- and makes the sum the window's minimum height.
--
-- The list is this screen's one elastic band -- it is anchored between the view
-- toggle and the totals banner, so every pixel a taller window adds lands there
-- -- and everything else is fixed. Each term below is read from the token
-- CT.Build anchors that band with, never restated as a number, so moving a band
-- moves the floor with it:
--
--   panel top
--     inset             the panel's own top margin
--   view toggle         segmentHeight (the C.O.D. hint shares this row, so it
--     gap               adds nothing to the height)
--   list container      tightGap, the scroll viewport, tightGap
--     gap
--   totals banner       controlHeight
--     gap
--   footer              the category grid: one full-width primary over two rows
--     inset             of three, or the primary alone when the option hides
--                       the five. The Done view swaps in a single delete button
--                       and is therefore SHORTER, so sizing for the grid is what
--                       makes the guarantee hold in both views. The floor
--                       follows the option, and Core/MailboxUI.lua moves a
--                       window standing on the old floor onto the new one.
function CT.MinPanelHeight()
  local M = Th().Metrics
  -- The footer as the option has it: with the five sweeps, or the primary
  -- alone. The floor follows the option so the list below it always shows
  -- whole rows -- a floor sized for a grid that is not there gave the list
  -- two rows' worth of pixels that were half a row too many.
  local footer = GRID_PRIMARY_HEIGHT
  if ShowCategoryButtons() then
    footer = footer + M.gap * 2 + GRID_BUTTON_HEIGHT * 2
  end
  return ceil(M.inset
            + M.segmentHeight + M.gap
            + (ListMinHeight() + 2 * M.tightGap) + M.gap
            + M.controlHeight + M.gap
            + footer
            + M.inset)
end

-------------------------------------------------------------
-- The inbox counts
--
-- THE numbers for "how much is there still to collect", and the only ones. All
-- three segment captions carry them, so they may never be able to disagree with
-- each other or with the list under them -- which they can only be guaranteed
-- not to if there is one walk of the inbox behind all of them, not three walks
-- that happen to use the same rule today. The shell's status line states no
-- count at all now, precisely because the segments already do.
--
-- So the list refresh, which has to reach a verdict on every mail anyway to
-- filter the list, RECORDS what it found here, and everything else READS. The
-- walk below exists for the two moments when nobody has recorded anything: the
-- option toggle (Core/MailboxUI.lua's RefreshCollectTabCounts, with no refresh
-- in flight to borrow from) and an inbox that changed while the collect panel
-- was hidden -- a hidden panel skips its refresh entirely, so the shell
-- invalidates on MAIL_INBOX_UPDATE and the next read pays for one walk.
--
-- The walk is not free: Mail().IsReadPersistent scans all sixteen attachment
-- slots of a mail its header calls empty. That is exactly why the recorded
-- answer is preferred and why there is no second counter anywhere.
-------------------------------------------------------------

local counts = { toCollect = 0, done = 0, total = 0, known = false }

local function RecordCounts(toCollect, done, total)
  counts.toCollect = toCollect
  counts.done = done
  counts.total = total
  counts.known = true
end

local function WalkCounts()
  local total = (type(GetInboxNumItems) == "function" and GetInboxNumItems()) or 0
  total = tonumber(total) or 0
  local done = 0
  for index = 1, total do
    if Mail().IsReadPersistent(index) then done = done + 1 end
  end
  RecordCounts(total - done, done, total)
end

-- -> toCollect, done, total.
function CT.InboxCounts()
  if not counts.known then WalkCounts() end
  return counts.toCollect, counts.done, counts.total
end

-- The inbox changed and no refresh has looked at it yet. Frozen: Core/MailboxUI.lua
-- calls this from MAIL_INBOX_UPDATE and when a mail session ends.
function CT.InvalidateCounts()
  counts.known = false
end

-------------------------------------------------------------
-- Refresh coalescing
--
-- A run refreshes the list once per mail. Rebuilding the list on each of those
-- inside the same frame is wasted work, and refreshing a panel nobody is
-- looking at is entirely wasted. Both collapse into one dirty flag: mark, drain
-- on the next frame, and skip while hidden -- the panel's OnShow drains it.
--
-- Published, because the shell needs it too: MAIL_INBOX_UPDATE is the burstiest
-- source of all (the initial inbox load, every body fetch, every CheckInbox) and
-- it used to reach RefreshMailList synchronously, which is several complete
-- rebuilds inside a handful of frames for one user-visible change. Every
-- event-driven refresh goes through here; only opening the window rebuilds
-- synchronously, because there the list has to exist in the frame the window
-- appears in.
-------------------------------------------------------------

local function RequestRefresh(panel)
  if not panel then return end
  panel._dirty = true
  if panel._refreshQueued then return end
  panel._refreshQueued = true
  -- The flag is a latch: nothing else ever clears it, so if the schedule failed
  -- the panel would never refresh again for the rest of the session. Unlatch and
  -- rebuild inline instead -- slower, but the list stays truthful.
  local ok = pcall(C_Timer.After, 0, function()
    panel._refreshQueued = false
    if panel._dirty then CT.RefreshMailList(panel) end
  end)
  if not ok then
    panel._refreshQueued = false
    CT.RefreshMailList(panel)
  end
end

CT.RequestRefresh = RequestRefresh

-------------------------------------------------------------
-- Confirmations
--
-- The client's own dialog: it sits above everything, is keyboard-dismissable,
-- and needs no skinning. When the dialog API is missing the message is printed
-- and NOTHING IRREVERSIBLE HAPPENS -- a missing confirmation is never an
-- implicit yes.
-------------------------------------------------------------

local POPUP_COD        = "POSTBOX_COD_CONFIRM"
local POPUP_BAGSPACE   = "POSTBOX_BAGSPACE_CONFIRM"
local POPUP_DELETE_ALL = "POSTBOX_DELETE_ALL_READ"
local POPUP_DELETE_ONE = "POSTBOX_DELETE_MAIL"
local POPUP_NOTICE     = "POSTBOX_COLLECT_NOTICE"

local function PopupsAvailable()
  return type(StaticPopupDialogs) == "table" and type(StaticPopup_Show) == "function"
end

-- No `preferredIndex` on any dialog below, deliberately. The field was a taint
-- mitigation: it asked StaticPopup for the last dialog frame, the one least
-- likely to be reused by secure code. 12.x's rewritten StaticPopup does not
-- read it at all -- dialogs come from a shared pool, first free frame -- and
-- STATICPOPUP_NUMDIALOGS no longer exists, so the helper that fed it always
-- returned nil. Nothing replaces it: GetReservedDialogFrame needs a reserved
-- frame an addon cannot create.
local function EnsureDialog(key, accept, cancel)
  if not PopupsAvailable() then return false end
  if StaticPopupDialogs[key] then return true end
  StaticPopupDialogs[key] = {
    text = "%s",
    button1 = accept,
    button2 = cancel,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, data)
      if type(data) == "table" and type(data.onConfirm) == "function" then data.onConfirm() end
    end,
  }
  return true
end

local function Confirm(key, accept, cancel, message, onConfirm)
  if EnsureDialog(key, accept, cancel) then
    StaticPopup_Show(key, message, nil, { onConfirm = onConfirm })
    return
  end
  ns.Print(message)
end

local function ShowNotice(message)
  if EnsureDialog(POPUP_NOTICE, L()["POPUP_OK"], nil) then
    StaticPopup_Show(POPUP_NOTICE, message)
    return
  end
  ns.Print(message)
end

-- Before collecting a single mail the player clicked. Bulk runs never include
-- C.O.D. mail -- the domain excludes it -- so this is the only path that can
-- spend the player's money.
--
-- The accept re-verifies the mail's identity: a StaticPopup is not modal, so
-- the inbox can reindex while the question waits (another row clicked, a
-- spontaneous inbox update), and the quoted amount must never be paid for
-- whatever mail slid onto the index since. Forward declaration -- Fingerprint
-- lives with the mail-identity block below.
local Fingerprint

local function ConfirmCOD(index, onConfirm)
  local _, _, _, _, _, cod = GetInboxHeaderInfo(index)
  local amount = tonumber(cod) or 0
  if amount <= 0 then
    onConfirm()
    return
  end
  local expected = Fingerprint(index)
  Confirm(POPUP_COD, L()["COD_CONFIRM_ACCEPT"], L()["COD_CONFIRM_CANCEL"],
    L()("COD_CONFIRM_MSG", Helpers().FormatMoney(amount)), function()
      -- Silently stand down on a mismatch, like every LiveIndex caller: the
      -- coalesced refresh has already re-bound the rows the player sees.
      if Fingerprint(index) ~= expected then return end
      onConfirm()
    end)
end

-------------------------------------------------------------
-- Words for a status code
--
-- ns.MailService reports what happened; which of those outcomes deserves a
-- chat line, and in what words, is this file's job.
--
--   "collected" the mail (or slot) is empty.
--   "refused"   the server declined specific attachments. They are still in the
--               mailbox, nothing is at risk, carry on.
--   "timeout"   the server stopped acknowledging commands. Stop.
--   "busy"      another Postbox sequence owns the command channel; the click is
--               a no-op and the run in progress reports its own status.
--   "closed"    the mailbox is not open.
-------------------------------------------------------------

-- When we captured the game's own error text we quote it, because it names the
-- actual cause. Without it we can only list the usual ones, so the fallback
-- offers them as possibilities rather than asserting a cause.
local function ItemRefusedMessage(reason)
  if reason and reason ~= "" then return L()("MSG_ITEM_REFUSED_REASON", reason) end
  return L()["MSG_ITEM_REFUSED"]
end

local function MailPartialMessage(refused, reason)
  if reason and reason ~= "" then return L()("MSG_MAIL_PARTIAL_REASON", refused, reason) end
  return L()("MSG_MAIL_PARTIAL", refused)
end

-- The one line a stuck mail gets, wherever it is shown -- the row's tooltip and
-- the detail view's metadata both read it from here, so the two can never say
-- different things about the same mail.
--
-- `reason` is what ns.MailService recorded: the game's own error text, or `true`
-- where it refused with nothing we could attribute to this mail. The generic
-- half is phrased as possibilities, never as a cause: the addon does not know
-- which of them it was, and guessing out loud is how a player ends up emptying a
-- bag over a unique item they already owned.
local function StuckLine(reason)
  local words = (type(reason) == "string" and reason ~= "") and reason
    or L()["STUCK_GENERIC"]
  return L()("STUCK_LINE", words)
end

-- A locale key that the locale pass has not added yet must not render as its
-- own name in the middle of the UI. Every new string in this file reads raw
-- first and composes a neutral fallback when the key is absent.
local function RawKey(key)
  local value = rawget(L(), key)
  if type(value) == "string" then return value end
  return nil
end

-------------------------------------------------------------
-- Mail identity
--
-- An inbox index stops naming a mail the moment that mail is emptied: the
-- server deletes it and every higher index slides down onto it. The detail view
-- is addressed by index, so it has to be able to notice.
-------------------------------------------------------------

-- Split from Fingerprint so a caller that has already read the header -- the row
-- binder reads all nine return values anyway -- can build the same string
-- without a second GetInboxHeaderInfo, and so the two can never disagree about
-- what a fingerprint is made of.
local function FingerprintOf(sender, subject, cod)
  if sender == nil and subject == nil then return nil end
  return tostring(sender) .. "\001" .. tostring(subject) .. "\001" .. tostring(tonumber(cod) or 0)
end

-- Declared `local` above ConfirmCOD, which closes over it; assigned here.
function Fingerprint(index)
  local _, _, sender, subject, _, cod = GetInboxHeaderInfo(index)
  return FingerprintOf(sender, subject, cod)
end

-- Any widget that stores `mailIndex` also stores the `fingerprint` the mail had
-- when that index was written to it. This returns the index only while the two
-- still agree, and nil otherwise.
--
-- The list re-binds on every refresh, but a refresh is COALESCED to the next
-- frame -- so between a take completing and that rebuild every row below the
-- emptied mail carries an index that has already slid onto its neighbour. That
-- window is long enough to hover in, and a tooltip read straight off an index
-- (GameTooltip:SetInboxItem takes one) would describe the wrong mail's item.
-- The check costs one header read on hover, which is where all of this is.
local function LiveIndex(widget)
  local index = widget and widget.mailIndex
  if not index or not widget.fingerprint then return nil end
  if Fingerprint(index) ~= widget.fingerprint then return nil end
  return index
end

-- The real item tooltip for an attachment still sitting in the mailbox.
--
-- SetInboxItem, not SetHyperlink: it is addressed by mail and slot and needs no
-- item link, which matters because an unread mail's attachment links are not
-- loaded until its body is fetched -- and not fetching the body is the entire
-- point of a preview.
local function ShowAttachmentTooltip(owner, index, slot)
  if not (owner and index and slot) then return false end
  if type(GameTooltip.SetInboxItem) ~= "function" then return false end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:ClearLines()
  GameTooltip:SetInboxItem(index, slot)
  GameTooltip:Show()
  return true
end

-------------------------------------------------------------
-- Per-mail economy
--
-- Derived from the invoice where one exists, and from the classification
-- otherwise. A buyer invoice is a purchase; a seller invoice counts the money
-- actually collectable from the mailbox, not the gross sale -- the deposit and
-- the auction house's cut never arrive.
-------------------------------------------------------------

local function MailEconomy(index, kind, money)
  local amount = tonumber(money) or 0
  local invoiceType, bid
  if type(GetInboxInvoiceInfo) == "function" then
    invoiceType, _, _, bid = GetInboxInvoiceInfo(index)
  end

  if invoiceType == "buyer" then
    bid = tonumber(bid) or 0
    if bid > 0 then return 0, bid end
    return 0, amount
  end

  if invoiceType == "seller" or invoiceType == "seller_temp_invoice" then
    return amount, 0
  end

  if kind == "bought" then return 0, amount end
  return amount, 0
end

-- The money lines an invoice is worth printing, in reading order, keyed by the
-- token the server puts on it. Naming the field rather than its position keeps
-- this readable next to a GetInboxInvoiceInfo call that discards four of its
-- seven returns.
--
-- `saleTotal` marks the one figure the two screens disagree about. A list row
-- already carries what the mail is worth NOW, and following that with the
-- gross sale reads as though the gold arrived twice; the overlay has the room
-- to show the whole breakdown and is the place a player goes to reconcile it.
local INVOICE_FIGURES = {
  seller = {
    { field = "bid",         label = "LABEL_SALE", saleTotal = true },
    { field = "deposit",     label = "LABEL_DEPOSIT" },
    { field = "consignment", label = "LABEL_AH_COMMISSION" },
  },
  buyer = {
    { field = "bid", label = "LABEL_PURCHASE" },
  },
}

-- A sale the server has not finished settling arrives under its own token and
-- reads identically.
INVOICE_FIGURES.seller_temp_invoice = INVOICE_FIGURES.seller

-- Reused for the same reason the row's own tables are: one mail is described
-- at a time, and this runs per visible row per refresh.
local invoiceAmounts = {}

-- Appends an auction mail's money breakdown to `parts`, and nothing at all for
-- a mail that has no invoice -- which includes every auction mail whose body
-- has not been fetched yet, since GetInboxInvoiceInfo stays silent until then.
--
-- Zero is not a figure: an auction that cost no deposit must not print a
-- deposit of nothing, and the same goes for a commission-free sale.
local function AppendInvoiceFigures(parts, index, withSaleTotal)
  if type(GetInboxInvoiceInfo) ~= "function" then return end

  local invoiceType, _, _, bid, _, deposit, consignment = GetInboxInvoiceInfo(index)
  local figures = INVOICE_FIGURES[invoiceType]
  if not figures then return end

  invoiceAmounts.bid = tonumber(bid) or 0
  invoiceAmounts.deposit = tonumber(deposit) or 0
  invoiceAmounts.consignment = tonumber(consignment) or 0

  local fmt = Helpers().FormatMoney
  for i = 1, #figures do
    local figure = figures[i]
    local amount = invoiceAmounts[figure.field]
    if amount > 0 and (withSaleTotal or not figure.saleTotal) then
      parts[#parts + 1] = L()[figure.label] .. fmt(amount)
    end
  end
end

-------------------------------------------------------------
-- Widths
--
-- A container anchored to its parent's edges measures zero until the first
-- layout pass. Every layout function below asks for its width through this, so
-- the synchronous pass at the end of build produces the same result the first
-- resize would -- which is the whole of the "controls jump into place a frame
-- after opening" defect.
-------------------------------------------------------------

local function UsableWidth(frame, fallback)
  local width = frame and frame:GetWidth() or 0
  if width and width > 10 then return width end
  return fallback
end

local function PanelWidth(panel)
  return UsableWidth(panel, FALLBACK_PANEL_WIDTH)
end

-------------------------------------------------------------
-- The view switch
--
-- A segmented control built from Theme.CreatePlate at its `segment` variant:
-- the same control the window tabs and the compose screen's category bar are
-- drawn from, so the three read as one family and there is one place to change
-- what a plate looks like.
--
-- This file used to carry a SECOND plate implementation. It read the theme's
-- plate TOKENS -- so it inherited the opacity fix when they were raised -- but
-- it drew no bevel, hardcoded the mouse-over wash at 1,1,1,0.05 instead of
-- plateHighlight, hardcoded the selected ring's alpha at 0.9 instead of
-- accentEdge, and painted the selected caption from the RAW accent rather than
-- the derived bright tone. On a dark host accent that last one is the
-- difference between a caption and a smudge, which is exactly what
-- Theme.GetAccentTone("bright") exists to prevent.
--
-- The active accent is still resolved on every repaint and never cached: the
-- factory reads Theme.GetAccentTone each time, and a host-UI skin publishing
-- the user's own accent re-drives this through CT.RepaintViewToggle.
--
-- The underline is the plate's own, not a texture parented to the container.
-- The container-owned one was defensive -- a skin's texture-stripping pass over
-- a button must not be able to take the only indication of which view is
-- showing -- and the factory answers that properly: every texture a plate owns
-- is filed in `__pbPlateArt`, and a skin that wants the selection visual
-- installs `__setSelectedOverride`, which retires that art wholesale rather
-- than stripping half of it. Neither shipped skin touches these buttons at all
-- (SkinTree only restyles frames tagged __postboxButton, which a flat segment
-- deliberately is not).
-------------------------------------------------------------

local function PaintViewToggle(panel)
  local container = panel and panel.ViewToggle
  if not container or not container.buttons then return end
  local T = Th()
  local active = panel.viewMode

  for i = 1, #container.buttons do
    local seg = container.buttons[i]
    T.SetPlateSelected(seg, seg.segId == active)
  end
end

-- Frozen: Core/Skin_EllesmereUI.lua calls this when the user changes their
-- accent colour live.
function CT.RepaintViewToggle(panel)
  PaintViewToggle(panel)
end

local SetViewMode  -- forward declaration; the segments call it

local function BuildViewToggle(panel)
  local T = Th()
  local container = CreateFrame("Frame", nil, panel)
  container:SetPoint("TOPLEFT", panel, "TOPLEFT", T.Metrics.inset, -T.Metrics.inset)
  container:SetHeight(T.Metrics.segmentHeight)

  container.buttons = {}
  -- The two halves first, then their union. Reading left to right that is
  -- "what is left, what is finished, everything" -- the order the counts add up
  -- in, which is the order a reader checks them in.
  local segments = {
    { id = VIEW_COLLECT, label = L()["VIEW_TO_COLLECT"] },
    { id = VIEW_DONE,    label = L()["VIEW_DONE"] },
    { id = VIEW_ALL,     label = L()["VIEW_ALL"] },
  }

  for i = 1, #segments do
    local seg = T.CreatePlate(container, "segment")
    seg.segId = segments[i].id
    -- The base caption is kept apart from the displayed text so the optional
    -- "(count)" suffix can be added and removed without corrupting the label.
    seg.baseLabel = segments[i].label
    seg:SetText(segments[i].label)
    seg:SetScript("OnClick", function(self) SetViewMode(panel, self.segId) end)
    -- Hover is the plate's own OnEnter/OnLeave, installed by the factory and
    -- deliberately left alone: these segments carry no tooltip, so there is
    -- nothing to hook and nothing to replace them with.
    container.buttons[i] = seg
  end

  panel.ViewToggle = container
end

-------------------------------------------------------------
-- Search
--
-- One box on the top row, right-aligned, narrowing the list to the mails
-- whose sender or subject contains what is typed. It is a view of the same
-- list, not a fourth view: the segment counts still describe the whole
-- inbox, and the totals banner still describes what is listed. While a
-- search is on, the five category sweeps are withdrawn and the full-width
-- button reads "Collect shown" and takes exactly the mails on screen --
-- "All mail" under a list of three would otherwise take fifty.
-------------------------------------------------------------

local SEARCH_W = 150

local function Trim(text)
  local H = ns.Helpers
  if H and H.NormalizeText then return H.NormalizeText(text) end
  return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

-- The query as typed, trimmed; "" when the box is empty or not built.
local function SearchQuery(panel)
  local box = panel and panel.SearchBox
  if not box then return "" end
  return Trim(box:GetText() or "")
end

local function Searching(panel)
  return SearchQuery(panel) ~= ""
end

-- The case fold the address book uses (Cyrillic-aware, see Lib/Util.lua),
-- so a Russian player searching in lowercase finds a capitalised sender.
local function Fold(text)
  local H = ns.Helpers
  if H and H.Lower then return H.Lower(text) end
  return string.lower(tostring(text or ""))
end

local function BuildSearchBox(panel)
  local T = Th()
  local M = T.Metrics

  local wrap = CreateFrame("Frame", nil, panel, "BackdropTemplate")
  wrap:SetSize(SEARCH_W, M.segmentHeight)
  wrap:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -M.inset, -M.inset)
  T.StyleInput(wrap)
  -- Both host skins act on this tag; the inner box is left to the wrap.
  wrap.__postboxInputWrap = true
  panel.SearchWrap = wrap

  local box = CreateFrame("EditBox", nil, wrap)
  box:SetAutoFocus(false)
  local font = T.FontObject("bodySmall")
  if font then box:SetFontObject(font) end
  T.SetColor(box, "textPrimary")
  box:SetPoint("TOPLEFT", wrap, "TOPLEFT", 8, -2)
  box:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -6, 2)
  box.__postboxNoEditSkin = true
  -- A sender is at most a name and a realm; a subject at most 64.
  box:SetMaxLetters(64)
  panel.SearchBox = box

  local placeholder = T.CreateText(wrap, "placeholder")
  placeholder:SetPoint("TOPLEFT", wrap, "TOPLEFT", 8, -2)
  placeholder:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -8, 2)
  placeholder:SetJustifyH("LEFT")
  placeholder:SetJustifyV("MIDDLE")
  placeholder:SetText(L()["SEARCH_PLACEHOLDER"])

  wrap:SetScript("OnMouseDown", function() box:SetFocus() end)
  box:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
  end)
  box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  box:SetScript("OnTextChanged", function(self)
    local text = self:GetText() or ""
    placeholder:SetShown(text == "")
    local searching = Trim(text) ~= ""
    -- The footer changes shape only when the search turns on or off, not on
    -- every keystroke inside one.
    if searching ~= (panel._searchOn == true) then
      panel._searchOn = searching
      CT.RefreshCategoryButtons(panel)
    end
    CT.RefreshMailList(panel)
  end)
end

-- Frozen: Core/MailboxUI.lua calls this when the mailbox closes. A search is
-- a question about THIS inbox; the next one starts unfiltered.
function CT.ClearSearch(panel)
  local box = panel and panel.SearchBox
  if box and box:GetText() ~= "" then box:SetText("") end
end

-------------------------------------------------------------
-- Selection
--
-- Pick the mails to collect before collecting them. Shift-click a row and
-- it is selected; shift-click another and everything between the two is;
-- ctrl-click picks or unpicks single rows anywhere. The gestures are the
-- file manager's, because that is where everyone learned them. Only mail
-- with something left to collect can be picked -- a finished mail has no
-- part in a collect run -- and a selection can be made inside a search:
-- the range runs over the rows on screen, whatever narrowed them.
--
-- The selection is a set of inbox INDICES, which is the one thing a collect
-- run needs and the one thing an inbox reindex invalidates. So it lives
-- exactly as long as the inbox it was made in: the moment the mail count
-- changes -- a collect, a delete, a return, new mail landing -- it is
-- dropped rather than allowed to name different mails. A run started from it
-- takes the selected indices through the same queue the sweeps use.
--
-- While anything is selected the footer behaves as it does under a search:
-- the category sweeps withdraw and the one button reads "Collect N
-- selected" and takes exactly those.
-------------------------------------------------------------

local function Selection(panel)
  local set = panel._selected
  if not set then
    set = {}
    panel._selected = set
  end
  return set
end

local function SelectionCount(panel)
  return panel._selectedCount or 0
end

local function Selecting(panel)
  return SelectionCount(panel) > 0
end

-- The selected rows' wash: the accent at low alpha over the stripe, and a
-- bar at the left edge. Separate textures over the row's own background,
-- so the hover repaint (which rewrites that background) leaves them be.
local function PaintRowSelection(panel, row)
  local on = panel._selected ~= nil and row.mailIndex ~= nil
    and panel._selected[row.mailIndex] == true
  if on and not row._selBar then
    local T = Th()
    row._selWash = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row._selWash:SetAllPoints()
    row._selBar = row:CreateTexture(nil, "ARTWORK")
    row._selBar:SetWidth(2)
    row._selBar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row._selBar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    local r, g, b = T.GetAccent()
    row._selWash:SetColorTexture(r, g, b, 0.14)
    row._selBar:SetColorTexture(r, g, b, 0.9)
  end
  if row._selBar then
    if on then
      -- Re-tinted on every paint: the accent can change under a host skin.
      local r, g, b = Th().GetAccent()
      row._selWash:SetColorTexture(r, g, b, 0.14)
      row._selBar:SetColorTexture(r, g, b, 0.9)
    end
    row._selWash:SetShown(on)
    row._selBar:SetShown(on)
  end
end

-- Re-paints every bound row and the footer: the primary button's caption
-- carries the count, so it is redrawn on every change and not only when the
-- selection appears or empties.
local function AfterSelectionChange(panel)
  local rows = panel._rows or {}
  for i = 1, #rows do
    if rows[i].mailIndex then PaintRowSelection(panel, rows[i]) end
  end
  CT.RefreshCategoryButtons(panel)
end

local function ClearSelection(panel)
  if not panel or not Selecting(panel) then return end
  panel._selected, panel._selectedCount = nil, 0
  panel._selectAnchor = nil
  AfterSelectionChange(panel)
end

local function SetSelected(panel, index, on)
  local set = Selection(panel)
  if (set[index] == true) == on then return end
  set[index] = on or nil
  panel._selectedCount = SelectionCount(panel) + (on and 1 or -1)
end

local function SelectToggle(panel, row)
  local index = row.mailIndex
  if not index then return end
  local set = Selection(panel)
  SetSelected(panel, index, not set[index])
  -- The row just picked is where the next shift-click measures from,
  -- picked or unpicked: that is the file manager's rule too.
  panel._selectAnchor = row._rowIndex
  AfterSelectionChange(panel)
end

-- Shift-click. A row that is already picked is unpicked -- shift is the
-- only modifier most people will reach for, so it has to be able to undo
-- what it did. Otherwise, with something picked, everything between the
-- anchor and this row is picked; with nothing picked, this row is.
local function SelectRange(panel, row)
  local index = row.mailIndex
  if not index then return end
  local set = Selection(panel)
  local anchor = panel._selectAnchor
  if set[index] or not anchor or not Selecting(panel) then
    SelectToggle(panel, row)
    return
  end
  local from, to = anchor, row._rowIndex or anchor
  if from > to then from, to = to, from end
  local filtered, done = panel._filtered, panel._filteredDone
  for position = from, to do
    local at = filtered[position]
    if at and not done[position] then SetSelected(panel, at, true) end
  end
  panel._selectAnchor = row._rowIndex
  AfterSelectionChange(panel)
end

-- The selected indices, highest first: the order a collect run wants them
-- in, so that taking one never shifts the ones still to come.
local function SelectionIndices(panel)
  local out = {}
  for index in pairs(panel._selected or {}) do out[#out + 1] = index end
  table.sort(out, function(a, b) return a > b end)
  return out
end

-- Sizes every segment to the longest rendered caption -- counts included -- and
-- lays them out. A fixed width sized for English "Read (99+)" is what clipped
-- the German and Russian captions into their neighbour.
-- The segments actually on screen, in order. Hiding one is a layout fact,
-- not a special case: everything below sizes and spaces what this returns.
local function VisibleSegments(container)
  local shown = {}
  for i = 1, #container.buttons do
    local seg = container.buttons[i]
    if seg.segId ~= VIEW_ALL or ShowAllSegment() then
      shown[#shown + 1] = seg
    else
      seg:Hide()
    end
  end
  for i = 1, #shown do shown[i]:Show() end
  return shown
end

local function LayoutViewToggle(panel)
  local container = panel.ViewToggle
  if not container or not container.buttons then return end
  local T = Th()
  -- The ladder's `snug` rung is defined as "two controls acting as one unit
  -- (the segments of a switch)", which is precisely what these are. It was
  -- tightGap, the padding rung, so the group read a shade tighter than the
  -- design says a switch should.
  local gap = T.Metrics.space.snug
  local shown = VisibleSegments(container)

  local per, total = T.SizeRow(shown, {
    height = T.Metrics.segmentHeight,
    gap = gap,
    minWidth = T.Metrics.buttonMinWidth,
  })

  for i = 1, #shown do
    local seg = shown[i]
    seg:ClearAllPoints()
    seg:SetPoint("LEFT", container, "LEFT", (i - 1) * (per + gap), 0)
  end
  container:SetWidth(max(total, 1))

  -- The hint shares the top row. It is genuinely optional text, so it is shown
  -- only when it fits beside the segments in full: clipping it would be worse
  -- than not showing it, and it has no frame of its own to hang a tooltip on.
  local hint = panel.Hint
  if hint then
    -- Less the search box on the same row, which has first claim on the right.
    local room = PanelWidth(panel) - 2 * T.Metrics.inset - total - T.Metrics.gap
    if panel.SearchWrap then room = room - SEARCH_W - T.Metrics.gap end
    hint:SetShown(room >= T.TextWidth(hint))
  end

  PaintViewToggle(panel)
end

-- Frozen: Core/MailboxUI.lua calls this when the All-segment option changes.
-- A hidden segment cannot be the one on screen, so the view falls back to
-- Collect -- and that path re-lays the row on its way through.
function CT.RefreshSegments(panel)
  if not panel or not panel.ViewToggle then return end
  if not ShowAllSegment() and panel.viewMode == VIEW_ALL then
    SetViewMode(panel, VIEW_COLLECT)
    return
  end
  LayoutViewToggle(panel)
end

-------------------------------------------------------------
-- Segment counts
-------------------------------------------------------------

local function FormatCount(n)
  if n > COUNT_CAP then return tostring(COUNT_CAP) .. "+" end
  return tostring(n)
end

-- panel -> nothing. The three numbers come from CT.InboxCounts and from nowhere
-- else, which is what guarantees the arithmetic a reader will do on them --
-- Collect + Done = All -- actually holds rather than merely tending to.
function CT.UpdateTabCounts(panel)
  local container = panel and panel.ViewToggle
  if not container or not container.buttons then return end

  local show = ShowTabCounts()
  -- Asked for only when a caption will carry it: with the option off the walk
  -- this can trigger would be paid for a number nobody is shown.
  local toCollect, done, total
  if show then toCollect, done, total = CT.InboxCounts() end

  for i = 1, #container.buttons do
    local seg = container.buttons[i]
    local base = seg.baseLabel or seg:GetText() or ""
    if show then
      local count = toCollect
      if seg.segId == VIEW_DONE then
        count = done
      elseif seg.segId == VIEW_ALL then
        count = total
      end
      seg:SetText(base .. " (" .. FormatCount(count) .. ")")
    else
      seg:SetText(base)
    end
  end

  -- The captions just changed length, so the row has to be measured again.
  LayoutViewToggle(panel)
end

-------------------------------------------------------------
-- Mail rows :: the pool
--
-- WoW cannot free a frame. The previous build hid every row and re-parented it
-- to nil on each refresh, then built fresh frames -- so a fifty-mail run, which
-- refreshes once per mail, leaked on the order of 2500 frames for the session.
--
-- Rows are therefore acquired by viewport slot and released by hiding. Every
-- script is installed once, at creation, and reads the mail it is bound to from
-- a field re-written on each bind: a closure per row per refresh is the second
-- leak, and the one that is easy to reintroduce.
-------------------------------------------------------------

local ShowDetail, CollectSingleMail, DeleteOneMail  -- forward declarations

-- ONE reading of a click on a mail row, and the only one. The row, the icon
-- hover area laid on top of it and the row's own tooltip hint all come through
-- here, so what a gesture does and what the tooltip says it does cannot drift
-- apart -- which they would the moment either was decided twice.
--
-- Two mappings, chosen by the `previewOnClick` option, and both are the same
-- pair of verbs the other way round:
--
--                     option OFF (default)      option ON
--   left              collect                   open the mail
--   right             open the mail             collect
--
-- Shift-click used to be a second spelling of right-click. It is a selection
-- gesture now (see "Selection"), which is why it appears in neither column.
--
-- A FINISHED mail has nothing to collect, so every button opens it under either
-- mapping. That is a property of the MAIL and not of the view it is being listed
-- in: the same mail behaves identically under "Done" and under "All", which is
-- what stops a gesture meaning two things depending on which segment is lit.
--
-- Why an alternate gesture exists at all: when the server refuses a take ("You
-- can't carry any more of those items") the mail stays in the to-collect list,
-- and without this the only way to see what is in it, or read what it says,
-- would be to collect it -- which is the thing that will not work.
--
-- Returns true to preview, false to collect.
local function PreviewGesture(row, button)
  if row.mailDone then return true end
  local alternate = (button == "RightButton")
  if PreviewOnClick() then return not alternate end
  return alternate
end

local function ActivateRow(row, button)
  local panel = row.panel
  local index = LiveIndex(row)
  if not (panel and index) then return end

  -- A modified left-click is a selection gesture, under either mapping and
  -- on either button's verb: shift extends a range from the last row picked,
  -- ctrl picks or unpicks the one row. See "Selection" above.
  if button == "LeftButton" and not row.mailDone then
    if IsShiftKeyDown() then SelectRange(panel, row) return end
    if IsControlKeyDown() then SelectToggle(panel, row) return end
  end

  if not PreviewGesture(row, button) then
    CollectSingleMail(panel, index)
    return
  end

  -- A run owns every inbox index for its whole duration, and the overlay is
  -- addressed by index -- CloseDetailIfStale hides it outright while one is
  -- active, so an overlay opened mid-run would appear and vanish. This is the
  -- same "one sequence at a time" the collect path gets for free from
  -- MailService's channel ownership; the preview path issues no command, so it
  -- has to state it.
  if CT.IsRunning() then return end
  ShowDetail(panel, index)
end

-------------------------------------------------------------
-- Mail rows :: the two layouts
--
--   STANDARD  two lines beside a 28px icon: sender and subject on the first,
--             the meta line -- gold, C.O.D., slots left, category, expiry,
--             invoice breakdown -- on the second.
--   COMPACT   one line beside an 18px icon: sender, then subject, with the
--             essentials of the meta line right-aligned at the trailing edge.
--             The category and the invoice breakdown are not drawn at all; the
--             row's hover tooltip carries the WHOLE meta line instead, so
--             nothing a standard row says stops being reachable.
--
-- A row is pooled and recycled between the two, so this re-anchors only when the
-- mode a row is wearing is not the mode it is being bound into -- which for the
-- overwhelmingly common case (the option never changes mid-session) is once, at
-- build. Everything that depends on the MAIL rather than on the layout -- which
-- trailing controls are showing, how wide each string may be -- stays in
-- BindRow.
--
-- `row._compact` starts nil, so a freshly built row is always laid out by the
-- first call: BuildRow deliberately leaves every mode-dependent size and anchor
-- unset rather than duplicating one of the two branches below.
-------------------------------------------------------------

local function ApplyRowMode(row, compact, height)
  if row._compact == compact then return end
  row._compact = compact

  local M = Th().Metrics
  local iconSize = compact and ROW_ICON_COMPACT or ROW_ICON
  local deleteSize = compact and ROW_DELETE_COMPACT or ROW_DELETE

  row:SetHeight(height)

  -- The hit area is SetAllPoints(row.Icon), so it follows both of these; the
  -- stripe is SetAllPoints(row), so it follows the height.
  row.Icon:SetSize(iconSize, iconSize)
  row.Icon:ClearAllPoints()
  -- Two past the indicator's slot, so the dot has a clear pixel or two
  -- between it and the icon; the text-width arithmetic in the binder counts
  -- the same two.
  row.Icon:SetPoint("LEFT", row, "LEFT", M.inset + ROW_INDICATOR + 2, 0)

  -- The BUTTON is the hit area and keeps the full size; only its glyph is inset.
  row.Delete:SetSize(deleteSize, deleteSize)
  if row._deleteTexture then
    local glyphSize = max(deleteSize - 2 * DELETE_GLYPH_INSET, 1)
    row.Delete.Glyph:SetSize(glyphSize, glyphSize)
  end
  -- Only the texture form has a size to give: the fallback is a font string
  -- carrying a single character, and constraining that would clip it.
  if row._warningTexture then
    local warningSize = compact and ROW_WARNING_COMPACT or ROW_WARNING
    row.Warning:SetSize(warningSize, warningSize)
  end

  row.Sender:ClearAllPoints()
  row.Subject:ClearAllPoints()
  row.Detail:ClearAllPoints()

  if compact then
    row.Sender:SetPoint("LEFT", row.Icon, "RIGHT", M.gap, 0)
    row.Subject:SetPoint("LEFT", row.Sender, "RIGHT", M.gap, 0)
    -- Right-aligned against the trailing edge. The offset is re-written on bind
    -- whenever it changes, because what sits outboard of it -- the delete
    -- control, the stuck marker -- is a property of the mail and of the view,
    -- not of the layout. `_detailTrailing` always describes the anchor the
    -- string is currently carrying.
    row.Detail:SetPoint("RIGHT", row, "RIGHT", -M.inset, 0)
    row._detailTrailing = M.inset
    row.Detail:SetJustifyH("RIGHT")
  else
    row.Sender:SetPoint("TOPLEFT", row.Icon, "TOPRIGHT", M.gap, 2)
    row.Subject:SetPoint("TOPLEFT", row.Sender, "TOPRIGHT", M.gap, 0)
    row.Detail:SetPoint("BOTTOMLEFT", row.Icon, "BOTTOMRIGHT", M.gap, -2)
    row._detailTrailing = nil
    row.Detail:SetJustifyH("LEFT")
  end
end

local function BuildRow(panel)
  local T = Th()
  local row = CreateFrame("Button", nil, panel.MailListChild)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row.panel = panel

  -- The read/unread mark: a flat dot in the theme's two colours. A dot, not
  -- a square, and one pixel smaller than the space it is given -- the row
  -- has two marks at its left edge now (the selection bar sits on the edge
  -- itself) and a square beside a bar read as one shape. Eight in from the
  -- edge: clear of the bar, clear of the icon.
  row.Indicator = row:CreateTexture(nil, "ARTWORK")
  row.Indicator:SetSize(ROW_INDICATOR - 1, ROW_INDICATOR - 1)
  row.Indicator:SetPoint("LEFT", row, "LEFT", 7, 0)
  row.Indicator:SetTexture(WHITE)
  if type(row.CreateMaskTexture) == "function" then
    local mask = row:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
                    "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(row.Indicator)
    row.Indicator:AddMaskTexture(mask)
  end

  -- Sized and anchored by ApplyRowMode, which the virtualiser calls before it
  -- binds anything to this row. Same for the two texts below it, the delete
  -- control and the stuck marker.
  row.Icon = row:CreateTexture(nil, "ARTWORK")
  row.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  -- The row's icon IS the first attachment whenever the mail has one -- that is
  -- what Mail().GetMailIcon resolves to -- so hovering it should say which item,
  -- at its real quality, with its real count. A texture cannot take mouse input,
  -- so the hover area is a button laid exactly over it; and because the whole
  -- row surface is clickable, that button has to forward its clicks or the icon
  -- would be a dead hole in the middle of the row.
  row.IconHit = CreateFrame("Button", nil, row)
  row.IconHit:SetAllPoints(row.Icon)
  row.IconHit:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row.IconHit:SetScript("OnClick", function(self, button)
    ActivateRow(self:GetParent(), button)
  end)
  row.IconHit:SetScript("OnEnter", function(self)
    local owner = self:GetParent()
    -- Moving onto a child that takes the mouse fires the ROW's OnLeave, so the
    -- hover paint is re-asserted here; without it the row visibly unhighlights
    -- while the cursor is still on it.
    Th().StyleMailRow(owner, owner._rowIndex, true)
    local index = LiveIndex(owner)
    if not (index and owner.iconSlot) then return end
    ShowAttachmentTooltip(self, index, owner.iconSlot)
  end)
  row.IconHit:SetScript("OnLeave", function(self)
    local owner = self:GetParent()
    Th().StyleMailRow(owner, owner._rowIndex, false)
    GameTooltip:Hide()
  end)

  row.Sender = T.CreateText(row, "label")
  row.Sender:SetJustifyH("LEFT")

  row.Subject = T.CreateText(row, "value")
  row.Subject:SetJustifyH("LEFT")

  -- Secondary, never the disabled font object: this line carries the gold, the
  -- C.O.D., the remaining slots, the category and the expiry. It is the densest
  -- line on the screen and it is not inactive.
  row.Detail = T.CreateText(row, "secondary")

  -- Shown on a DONE mail, wherever that mail is being listed. Built once and
  -- shown per bind, because a row is recycled between the views. Its anchor is
  -- the same in both layouts; only its size steps down with the row.
  --
  -- A MARK, NOT A PLATE. It sits inside a list of mails, most of which do not
  -- carry it, so it may not have a filled surface of its own in either state:
  -- an opaque square is heavier than the row it annotates and reads as the
  -- loudest thing on the screen. Idle is the same neutral the row's own
  -- secondary text is; hover swaps the tint to `negative`, which is the tone
  -- this addon uses for everything that costs the player something. Nothing is
  -- drawn behind it in either state.
  row.Delete = CreateFrame("Button", nil, row)
  row.Delete:SetPoint("RIGHT", row, "RIGHT", -T.Metrics.tightGap, 0)

  local deleteAtlasName = ProbeAtlas(DELETE_ATLASES)
  if deleteAtlasName then
    row.Delete.Glyph = row.Delete:CreateTexture(nil, "ARTWORK")
    row.Delete.Glyph:SetAtlas(deleteAtlasName, false)
    row.Delete.Glyph:SetPoint("CENTER")
    -- Which of the two representations this row got: ApplyRowMode sizes a
    -- texture and must not constrain the font string, which would clip it.
    row._deleteTexture = true
  else
    row.Delete.Glyph = T.CreateText(row.Delete, "value")
    row.Delete.Glyph:SetPoint("CENTER")
    row.Delete.Glyph:SetText(DELETE_GLYPH)
  end
  -- Theme.SetColor tints a texture and colours a font string, so neither this
  -- nor the hover handlers below has to know which of the two it got.
  T.SetColor(row.Delete.Glyph, "textSecondary")

  row.Delete:SetScript("OnEnter", function(self)
    -- Same reason as the icon hover area: this is a child that takes the mouse,
    -- so the row's own OnLeave has just fired and the hover paint needs
    -- re-asserting or the row dims under the cursor.
    local owner = self:GetParent()
    local T2 = Th()
    T2.StyleMailRow(owner, owner._rowIndex, true)
    T2.SetColor(self.Glyph, "negative")
    -- The same shape every other tooltip in this file uses: own the tooltip,
    -- clear it, title, then a wrapped line under it. SetText alone gave a
    -- one-word tooltip that said no more than the glyph already does.
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:SetText(DeleteLabel())
    local hint = RawKey("HINT_ROW_DELETE")
    if hint then GameTooltip:AddLine(hint, 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  row.Delete:SetScript("OnLeave", function(self)
    local owner = self:GetParent()
    local T2 = Th()
    T2.StyleMailRow(owner, owner._rowIndex, false)
    T2.SetColor(self.Glyph, "textSecondary")
    GameTooltip:Hide()
  end)
  row.Delete:SetScript("OnClick", function(self)
    local parent = self:GetParent()
    -- Verified, not assumed: deleting is irreversible, so it may only ever act
    -- on an index that still names the mail this row is showing.
    DeleteOneMail(parent.panel, LiveIndex(parent))
  end)

  -- The stuck marker: this mail's attachments were refused by the server
  -- earlier in this visit. Never shown for a mail that merely HAS attachments --
  -- most of the list has those -- so it carries information every time it
  -- appears, and there is nothing to switch off when nothing is wrong.
  --
  -- A texture, not a button. The reason is read from the row's own hover
  -- tooltip, which is already on screen when the cursor is anywhere on the row,
  -- so the marker takes no mouse input and cannot become a dead spot in the
  -- middle of a clickable row the way an inert child frame would.
  local warningAtlasName = ProbeAtlas(Th().AtlasSets.warning)
  if warningAtlasName then
    row.Warning = row:CreateTexture(nil, "OVERLAY")
    row.Warning:SetAtlas(warningAtlasName, false)
    -- Which of the two representations this row got. ApplyRowMode may resize a
    -- texture and may not resize the glyph.
    row._warningTexture = true
  else
    row.Warning = T.CreateText(row, "value")
    row.Warning:SetText(WARNING_GLYPH)
  end
  -- One tone for both representations, from the palette. Theme.SetColor tints a
  -- texture and colours a font string, so the caller does not have to know which
  -- of the two it got.
  T.SetColor(row.Warning, "warning")
  row.Warning:Hide()

  row:SetScript("OnClick", function(self, button) ActivateRow(self, button) end)

  row:SetScript("OnEnter", function(self)
    local T2 = Th()
    T2.StyleMailRow(self, self._rowIndex, true)

    -- A compact row draws a subset of the meta line, so it hands the WHOLE of
    -- it to the tooltip -- category and invoice breakdown included -- and the
    -- Detail string's own overflow is not asked about, because the full line
    -- already contains it. `detailFull` is nil on a standard row, where the
    -- line is on screen in full or was cut and is the overflow line's business.
    local full = self.detailFull
    local cut = self.Sender.__pbOverflowText or self.Subject.__pbOverflowText
      or (not full and self.Detail.__pbOverflowText)

    -- The gesture line is the one reason this tooltip is no longer conditional
    -- on something having been cut: shift-click and right-click cannot be
    -- discovered by looking. Which line it is follows the ACTIVE mapping -- the
    -- alternate gesture teaches whichever verb the plain click is not -- because
    -- a hint that describes the other setting is worse than no hint at all. A
    -- finished mail still gets nothing: there every button opens the mail, so
    -- there is no alternative to teach -- and that is read from the MAIL, so it
    -- holds on the all view too.
    local teach = nil
    if not self.mailDone then
      teach = PreviewOnClick() and RawKey("HINT_ROW_COLLECT") or RawKey("HINT_ROW_PREVIEW")
    end
    local stuck = self.stuckReason
    if not cut and not full and not teach and not stuck then return end

    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    T2.AddOverflowLine(self.Sender, GameTooltip)
    T2.AddOverflowLine(self.Subject, GameTooltip)
    if full then
      GameTooltip:AddLine(full, 1, 1, 1, true)
    else
      T2.AddOverflowLine(self.Detail, GameTooltip)
    end
    -- After the mail's own text, which identifies WHICH mail this is, and before
    -- the generic gesture hint: this line is about this mail and it is the
    -- reason the marker is there.
    if stuck then
      GameTooltip:AddLine(T2.Colorize("warning", StuckLine(stuck)), 1, 1, 1, true)
    end
    if teach then GameTooltip:AddLine(teach, 0.7, 0.7, 0.7, true) end
    -- The selection gestures, on the same rows the teach line is about: a
    -- finished mail cannot be picked, so it gets neither line.
    if not self.mailDone then
      local pick = RawKey("HINT_ROW_SELECT")
      if pick then GameTooltip:AddLine(pick, 0.7, 0.7, 0.7, true) end
    end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function(self)
    Th().StyleMailRow(self, self._rowIndex, false)
    GameTooltip:Hide()
  end)

  -- A row is never handed back without a height and without its icon anchored:
  -- the hit area is SetAllPoints(row.Icon) and would have nothing to follow. The
  -- virtualiser applies the mode again before every bind, which is a no-op
  -- unless the option changed in between.
  local compact, height = RowMetrics()
  ApplyRowMode(row, compact, height)

  return row
end

local function AcquireRow(panel, slot)
  local row = panel._rows[slot]
  if row then return row end
  row = BuildRow(panel)
  panel._rows[slot] = row
  return row
end

-------------------------------------------------------------
-- Mail rows :: the bind
--
-- `position` is the row's DISPLAYED position, not its inbox index. The list is
-- filtered by view mode, so striping by inbox index shows three identically
-- shaded rows in a row in the read view.
--
-- `done` is the verdict the list walk already reached for this mail. It is
-- passed in rather than recomputed: Mail().IsReadPersistent scans all sixteen
-- attachment slots, and the walk that filtered the list has just paid for it.
-- Everything that follows from "this mail is finished" -- the delete control,
-- the click mapping, the tooltip's gesture hint -- reads THIS and never the
-- view, which is the whole of what makes the all view work.
-------------------------------------------------------------

local function BindRow(panel, row, index, position, compact, done)
  local T = Th()
  local M = T.Metrics
  local fmt = Helpers().FormatMoney
  local labels = Labels()

  local _, _, sender, subject, money, cod, daysLeft, itemCount, wasRead = GetInboxHeaderInfo(index)
  local kind, hasCOD = Mail().ClassifyMail(index)
  local moneyValue = tonumber(money) or 0
  local codValue = tonumber(cod) or 0
  -- A finished mail is the only thing there is to delete from here, and it
  -- carries the control in every view that lists it.
  local showDelete = (done == true)
  -- Read before the columns are measured, because a marked row gives up the
  -- width the marker occupies and the text must not run under it. Free when
  -- nothing has been refused this visit -- the domain answers from an empty
  -- registry without touching the inbox.
  local stuckReason = Mail().StuckReason(index)
  local deleteSize = compact and ROW_DELETE_COMPACT or ROW_DELETE
  local warningSize = compact and ROW_WARNING_COMPACT or ROW_WARNING

  row.mailIndex = index
  row.mailDone = showDelete
  -- Written from the header just read, so identity costs no extra API call. Read
  -- back by LiveIndex before anything acts on -- or describes -- this row's
  -- index; see the comment there for the window it closes.
  row.fingerprint = FingerprintOf(sender, subject, cod)
  -- StyleMailRow writes _rowIndex / _hovered, which the hover handlers repaint
  -- from. `position` is the DISPLAYED position, never the inbox index.
  T.StyleMailRow(row, position, false)
  PaintRowSelection(panel, row)

  T.SetColor(row.Indicator, wasRead and "read" or "unread")
  row.Icon:SetTexture(Mail().GetMailIcon(index))
  row.Delete:SetShown(showDelete)
  -- Back to the idle tint, for the same reason StyleMailRow above re-asserts the
  -- unhovered row: this row is being bound to a different mail, so whatever
  -- hover state the last one left on it is not this one's.
  if showDelete then T.SetColor(row.Delete.Glyph, "textSecondary") end

  -- The marker sits at the trailing edge, inside the delete control wherever
  -- one is showing, so the two can never overlap. Anchored on bind rather than
  -- at build because which of the two offsets applies is a property of the view
  -- the row is currently bound into, and a row is recycled between both.
  row.stuckReason = stuckReason
  if stuckReason then
    row.Warning:ClearAllPoints()
    row.Warning:SetPoint("RIGHT", row, "RIGHT",
      -(M.tightGap + (showDelete and (deleteSize + M.tightGap) or 0)), 0)
    row.Warning:Show()
  else
    row.Warning:Hide()
  end

  -- One scan of the attachment slots, not two, and none at all for a mail whose
  -- header says it has no attachments. This runs for every visible row on every
  -- refresh, and a run refreshes once per mail.
  local remaining, quantity = 0, 0
  -- Which slot the row's icon came from, so hovering it can raise that item's
  -- own tooltip. Mail().GetMailIcon returns the first slot bearing a texture, so
  -- this has to find the same one -- and after a partial take that is not
  -- necessarily slot 1.
  local iconSlot = nil
  if (tonumber(itemCount) or 0) > 0 then
    for slot = 1, Mail().MAX_ATTACHMENTS do
      if GetInboxItemLink(index, slot) then remaining = remaining + 1 end
      local _, _, texture, count = GetInboxItem(index, slot)
      if texture and not iconSlot then iconSlot = slot end
      quantity = quantity + (tonumber(count) or 0)
    end
  end
  row.iconSlot = iconSlot

  -- What the trailing controls take out of the row, stacking inwards from its
  -- right edge. One number, read by both layouts: the standard row measures its
  -- text area against it and the compact row anchors its meta strip to it, so
  -- the two can never disagree about where the text has to stop.
  local trailing = M.inset
  if showDelete then trailing = trailing + deleteSize + M.tightGap end
  if stuckReason then trailing = trailing + warningSize + M.tightGap end

  -- Widths derived from the list's own width, so a caption is truncated with a
  -- tooltip rather than clipped, in any locale and at any window size.
  local iconSize = compact and ROW_ICON_COMPACT or ROW_ICON
  local textWidth = UsableWidth(panel.MailListChild, FALLBACK_PANEL_WIDTH - 2 * M.inset)
    - (M.inset + ROW_INDICATOR + 2 + iconSize + M.gap) - trailing
  textWidth = max(textWidth, 60)

  -- A partially collected auction stack must not keep advertising the quantity
  -- it arrived with, so a parenthesised count is rewritten to what is left.
  -- Only a TRAILING count: that is where the auction house writes it, and a
  -- player-written subject may contain parenthesised numbers of its own.
  -- An auction subject is shown as the item's name alone: the sender column
  -- already says "Auction House" and the category says what kind of mail it
  -- is, so "Auction won:" was the same fact a third time, and the part that
  -- pushed the item's name off the end of the row.
  local displaySubject = Helpers().ShortSubject(subject or "")
  if quantity > 0 then
    displaySubject = (displaySubject:gsub("%(%d+%)%s*$", "(" .. quantity .. ")"))
  end

  -- The meta line, and -- for the compact layout -- the subset of it that stays
  -- on the row. `parts` is what the standard row draws and what the compact
  -- row's tooltip carries whole; `brief` is what a mail is WORTH and how long it
  -- has left, which is the part a one-line row cannot make the reader hover for.
  -- The category and the invoice breakdown are the two that describe rather than
  -- alert, so they are the two that move.
  --
  -- Both tables live on the panel and are reused: this runs for every visible
  -- row on every refresh, and a run refreshes once per mail.
  local parts, brief = panel._rowParts, panel._rowBrief
  Clear(parts)
  Clear(brief)

  if moneyValue > 0 then
    local gold = L()["LABEL_GOLD"] .. fmt(moneyValue)
    parts[#parts + 1] = gold
    brief[#brief + 1] = gold
  end
  if hasCOD then
    local codText = (codValue > 0)
      and T.Colorize("negative", L()["LABEL_COD"] .. fmt(codValue))
      or T.Colorize("negative", L()["LABEL_COD_SHORT"])
    parts[#parts + 1] = codText
    brief[#brief + 1] = codText
  end
  if remaining > 0 then
    local slots = T.Colorize("accent", ns.Plural("COUNT_SLOTS", remaining))
    parts[#parts + 1] = slots
    brief[#brief + 1] = slots
  end
  parts[#parts + 1] = labels[kind] or kind
  if daysLeft then
    local expiry = format(L()["DAYS_SHORT"], daysLeft)
    parts[#parts + 1] = expiry
    brief[#brief + 1] = expiry
  end

  AppendInvoiceFigures(parts, index, false)

  local senderText = sender or L()["SENDER_UNKNOWN"]
  -- Auction mail says what happened where the sender would be: "Sold",
  -- "Won", "Expired", "Cancelled", each in its own colour, with the item's
  -- name beside it. "Auction House" carried no information the outcome
  -- does not, and the outcome was the one thing the row did not say.
  local outcome = AUCTION_OUTCOME[kind]
  if outcome then
    senderText = T.Colorize(outcome.role, L()[outcome.key])
  end

  if compact then
    -- Everything the row no longer draws goes to the tooltip, in full.
    row.detailFull = concat(parts, ROW_META_JOIN)

    -- The meta strip claims what it needs and never more than its share; what
    -- is left is the line the sender and the subject share.
    local metaCap = floor(textWidth * COMPACT_META_SHARE)
    local metaText = concat(brief, COMPACT_META_JOIN)
    T.FitText(row.Detail, metaCap, metaText, row.Detail)
    -- FitText reports the width the string WANTS, so a strip narrower than its
    -- allowance gives the difference back to the subject instead of leaving a
    -- ragged gap in the middle of every row.
    local metaWidth = (metaText ~= "") and min(ceil(T.TextWidth(row.Detail)), metaCap) or 0
    row.Detail:SetWidth(max(metaWidth, 1))
    if row._detailTrailing ~= trailing then
      row._detailTrailing = trailing
      row.Detail:ClearAllPoints()
      row.Detail:SetPoint("RIGHT", row, "RIGHT", -trailing, 0)
    end

    -- The sender is measured first and keeps only what it actually needs, up to
    -- the same share of the line it gets in the standard layout: a name is what
    -- a mailbox is scanned by, and the subject is what there is most of to cut.
    local lineWidth = max(textWidth - ((metaWidth > 0) and (metaWidth + M.gap) or 0), 40)
    local senderCap = min(max(floor(lineWidth * SENDER_SHARE), SENDER_MIN), SENDER_MAX)
    senderCap = min(senderCap, floor(lineWidth / 2))
    T.FitText(row.Sender, senderCap, senderText, row.Sender)
    local senderWidth = min(ceil(T.TextWidth(row.Sender)), senderCap)
    row.Sender:SetWidth(max(senderWidth, 1))
    T.FitText(row.Subject, max(lineWidth - senderWidth - M.gap, 20), displaySubject, row.Subject)
  else
    row.detailFull = nil

    local senderWidth = min(max(floor(textWidth * SENDER_SHARE), SENDER_MIN), SENDER_MAX)
    senderWidth = min(senderWidth, floor(textWidth / 2))
    T.FitText(row.Sender, senderWidth, senderText, row.Sender)
    T.FitText(row.Subject, max(textWidth - senderWidth - M.gap, 20), displaySubject, row.Subject)
    T.FitText(row.Detail, textWidth, concat(parts, ROW_META_JOIN), row.Detail)
  end

  row:Show()
end

-------------------------------------------------------------
-- Mail rows :: the virtualiser
--
-- Only the rows the viewport can show are materialised. The pool therefore
-- never grows past one screenful however large the inbox is, and a refresh is a
-- re-bind of frames that already exist rather than a rebuild.
-------------------------------------------------------------

local function UpdateVisibleRows(panel)
  local compact, height, stride = RowMetrics()
  -- The stride this pass laid the list out at. Read by CT.ApplyRowLayout, which
  -- has to convert a scroll offset taken under one stride into the same place
  -- under the other; nothing else may write it.
  panel._rowStride = stride
  local filtered = panel._filtered
  local scroll = panel.MailListScroll
  local viewport = scroll:GetHeight() or 0
  local offset = scroll:GetVerticalScroll() or 0

  local first = max(1, floor(offset / stride) + 1)
  local last = first - 1
  if viewport > 0 then
    last = min(#filtered, ceil((offset + viewport) / stride))
  end

  local used = 0
  for i = first, last do
    used = used + 1
    local row = AcquireRow(panel, used)
    -- Before the bind, and before the row is positioned: this is what gives a
    -- freshly built row its height, and what re-lays a pooled one the first time
    -- it is bound after the option changed.
    ApplyRowMode(row, compact, height)
    local y = -((i - 1) * stride)
    -- Two corner points on the same edge fix the width and the top without
    -- constraining the vertical centre, which would fight SetHeight.
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", panel.MailListChild, "TOPLEFT", 0, y)
    row:SetPoint("TOPRIGHT", panel.MailListChild, "TOPRIGHT", 0, y)
    BindRow(panel, row, filtered[i], i, compact, panel._filteredDone[i])
  end

  for i = used + 1, #panel._rows do
    local row = panel._rows[i]
    -- Everything the row knows about a mail goes with the mail. A released row
    -- names nothing, so nothing it is still holding can act or be described.
    row.mailIndex = nil
    row.mailDone = nil
    row.fingerprint = nil
    row.iconSlot = nil
    row.stuckReason = nil
    row.detailFull = nil
    row.Warning:Hide()
    row:Hide()
  end
  -- Rows carry no skinnable children -- no tagged push button, no themed panel,
  -- no edit box -- so a newly grown pool entry needs no ns.Skin.Refresh pass.
  -- Adding one here would re-walk the whole panel on every scroll tick.
end

-------------------------------------------------------------
-- The totals banner
-------------------------------------------------------------

local function UpdateBanner(panel, earned, spent)
  if not panel.Banner then return end
  local T = Th()
  local icons = ns.Core.Formatting.FormatMoneyIcons
  panel.BannerText:SetText(
    L()["BANNER_EARNED"] .. icons(earned, "ff" .. T.Hex.positive) ..
    "   |   " ..
    L()["BANNER_SPENT"] .. icons(spent, "ff" .. T.Hex.negative))
end

-------------------------------------------------------------
-- The list
-------------------------------------------------------------

local CloseDetailIfStale  -- forward declaration

-- The inbox can hold more mail than the server will address at once. Saying so
-- is the difference between "you have collected everything" and "you have
-- collected everything the game would show us".
--
-- The hint line is the natural place for it, but that line yields to the view
-- segments when a long translation leaves no room -- and a notice the player
-- may not see is not a notice. So it is also said once in chat, on the
-- transition into the truncated state.
local function UpdateHint(panel, numItems, totalItems)
  local hint = panel.Hint
  if not hint then return end

  local truncated = totalItems > numItems
  if truncated then
    local template = RawKey("MSG_INBOX_TRUNCATED")
    -- Until the locale pass adds the key, a bare ratio: no language at all, so
    -- it cannot read wrongly in any of the five.
    local text = template and format(template, numItems, totalItems)
      or format("%d / %d", numItems, totalItems)
    hint:SetText(text)
    if not panel._truncationTold then
      panel._truncationTold = true
      ns.Print(text)
    end
  else
    -- Nothing to say. This line used to carry "C.O.D. mail is never taken
    -- automatically" -- a promise the screen keeps anyway, standing on the
    -- top row of every visit to reassure about something that has not
    -- happened. The confirmation dialog is where that fact belongs, and it
    -- is already there.
    hint:SetText("")
    panel._truncationTold = false
  end
end

function CT.RefreshMailList(panel)
  if not panel or not panel.MailListChild then return end
  -- Refreshing a panel nobody can see is wasted work; the OnShow handler drains
  -- the flag.
  if not panel:IsShown() then
    panel._dirty = true
    return
  end
  panel._dirty = false

  CloseDetailIfStale(panel)

  local numItems, totalItems = 0, 0
  if type(GetInboxNumItems) == "function" then
    numItems, totalItems = GetInboxNumItems()
    numItems = tonumber(numItems) or 0
    totalItems = tonumber(totalItems) or numItems
  end

  -- A selection names inbox indices, and a changed count means those indices
  -- name different mails now. Dropped before the list is rebuilt, so no row
  -- is ever painted as picked for a mail nobody picked.
  if panel._lastNumItems ~= numItems then
    panel._lastNumItems = numItems
    ClearSelection(panel)
  end

  local filtered, filteredDone = panel._filtered, panel._filteredDone
  Clear(filtered)
  Clear(filteredDone)

  -- The all view applies no filter; the other two keep the mails whose verdict
  -- matches. One predicate, one pass, whichever of the three is showing.
  local view = panel.viewMode
  local showAll = (view == VIEW_ALL)
  local wantFinished = (view == VIEW_DONE)
  local earned, spent = 0, 0
  -- Tallied here rather than by a second walk anywhere else. Every consumer
  -- wants the same verdict for the same mails, and that verdict is the expensive
  -- one: IsReadPersistent scans all sixteen attachment slots of every finished
  -- mail, so a second walk cost a fifty-mail inbox some eight hundred redundant
  -- API calls on every single refresh. This walk is the one that records; see
  -- "The inbox counts".
  local doneCount, toCollectCount = 0, 0
  -- The search, folded once. Matched against the sender and the subject as
  -- the client reports them; the counts above are deliberately NOT narrowed
  -- by it, because the segment captions describe the inbox, not the view.
  local query = Fold(SearchQuery(panel))

  for index = 1, numItems do
    -- "Read" alone will not do: collecting marks every mail read as a side
    -- effect of loading its attachments, so a mail that was read but still
    -- holds items -- the normal outcome when bags fill mid-run -- has to stay
    -- in the actionable list.
    local finished = Mail().IsReadPersistent(index)
    if finished then
      doneCount = doneCount + 1
    else
      toCollectCount = toCollectCount + 1
    end
    local listed = showAll or finished == wantFinished
    local money
    if listed then
      local _, _, sender, subject
      _, _, sender, subject, money = GetInboxHeaderInfo(index)
      if query ~= "" then
        listed = Fold(sender or ""):find(query, 1, true) ~= nil
              or Fold(subject or ""):find(query, 1, true) ~= nil
      end
    end
    if listed then
      filtered[#filtered + 1] = index
      -- The verdict travels with the index, so the row binder never repeats the
      -- sixteen-slot scan this walk has already paid for.
      filteredDone[#filtered] = finished
      local kind = Mail().ClassifyMail(index)
      local rowEarned, rowSpent = MailEconomy(index, kind, money)
      earned = earned + rowEarned
      spent = spent + rowSpent
    end
  end

  local _, _, stride = RowMetrics()
  panel.MailListChild:SetHeight(max(#filtered * stride, 1))

  -- A shorter list can leave the scroll offset past the new end, which would
  -- render an empty viewport over a list that has content.
  local scroll = panel.MailListScroll
  local maxScroll = max(0, #filtered * stride - (scroll:GetHeight() or 0))
  if (scroll:GetVerticalScroll() or 0) > maxScroll then scroll:SetVerticalScroll(maxScroll) end
  if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end

  UpdateVisibleRows(panel)

  -- One sentence per view, each true of exactly that view: "nothing to collect"
  -- on a mailbox that still holds finished mail would be right and would read as
  -- a lie on the all view, where those mails are on screen.
  local emptyKey = "EMPTY_LIST"
  if query ~= "" then
    emptyKey = "EMPTY_LIST_SEARCH"
  elseif showAll then
    emptyKey = "EMPTY_LIST_ALL"
  elseif wantFinished then
    emptyKey = "EMPTY_LIST_DONE"
  end
  panel.Empty:SetText(L()[emptyKey])
  panel.Empty:SetShown(#filtered == 0)

  UpdateBanner(panel, earned, spent)
  -- The verdicts this walk reached, published before anything renders them: all
  -- three segment captions are readings of these two numbers, and `numItems` --
  -- what the client can actually address -- is the total they add up to and the
  -- number the all segment carries.
  RecordCounts(toCollectCount, doneCount, numItems)
  -- Hint first, counts second: both change the width of something in the top
  -- row, and UpdateTabCounts ends in the one layout pass that measures it.
  UpdateHint(panel, numItems, totalItems)
  CT.UpdateTabCounts(panel)
  -- The stuck registry can have changed under this refresh, so the idle line is
  -- re-rendered rather than left showing whatever the last inbox event computed.
  RefreshIdleSummary()

  -- A run owns the status line for its whole duration. Re-asserting it here
  -- means nothing else can leave a stale idle summary on screen mid-run.
  if CT.IsRunning() then CT.RefreshRunStatus() end
end

-- The row layout option changed. Frozen: Core/MailboxUI.lua calls this from the
-- options panel's checkbox.
--
-- A refresh IS the relayout -- it re-binds every visible row, and a bind goes
-- through ApplyRowMode -- so the only thing this has to add is the scroll
-- position. That is stored in PIXELS, and the same pixel offset names a
-- different mail the instant the stride changes; carrying it across as the
-- fractional row it was pointing at is what stops the list jumping somewhere
-- else the moment a display option is toggled.
function CT.ApplyRowLayout(panel)
  if not panel or not panel.MailListChild then return end
  -- The rebuild is what applies the new layout and it will not run on a hidden
  -- panel. Mark it instead; the panel's OnShow drains the flag.
  if not panel:IsShown() then
    RequestRefresh(panel)
    return
  end

  local scroll = panel.MailListScroll
  local previous = panel._rowStride or 0
  local anchor = (previous > 0) and ((scroll:GetVerticalScroll() or 0) / previous) or 0

  CT.RefreshMailList(panel)

  local stride = panel._rowStride or 0
  if stride <= 0 then return end
  local maxScroll = max(0, #panel._filtered * stride - (scroll:GetHeight() or 0))
  scroll:SetVerticalScroll(min(anchor * stride, maxScroll))
  if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
  -- Explicit rather than left to the scroll frame's own handler: that fires only
  -- when the offset actually moved, and when it did not the rows the refresh
  -- just bound are already the right ones -- so this is a no-op in the one case
  -- and the whole point in the other.
  UpdateVisibleRows(panel)
end

-- The shell nudges the list on MAIL_SUCCESS. Coalesced like every other
-- refresh, so a burst of successes during a run costs one rebuild per frame.
function CT.OnMailSuccess()
  local UI = ns.MailboxUI
  local panel = UI and UI._frame and UI._frame.Tabs and UI._frame.Tabs.collect
  RequestRefresh(panel)
end

-------------------------------------------------------------
-- Single-mail actions
-------------------------------------------------------------

function CollectSingleMail(panel, index, opts)
  ConfirmCOD(index, function()
    -- The one path allowed to pay a C.O.D. -- the player just confirmed this
    -- exact mail's amount (or it has none). The service refuses everywhere
    -- else, whatever mail an index turns out to name (see Mail.CollectMail).
    local confirmed = {}
    if type(opts) == "table" then
      for k, v in pairs(opts) do confirmed[k] = v end
    end
    confirmed.allowCOD = true
    local _, _, _, _, _, codBefore = GetInboxHeaderInfo(index)
    codBefore = tonumber(codBefore) or 0
    Mail().CollectMail(index, function(status, refused, reason)
      -- A confirmed C.O.D. that actually changed hands is reported in chat,
      -- with the amount: "collected" means the mail emptied (the first take
      -- pays), and a partial refusal has paid exactly when the mail's own
      -- C.O.D. field reads zero afterwards -- the mail is still at this index
      -- in that case, since only an emptied mail is deleted out from under it.
      if codBefore > 0 then
        local paid = status == "collected"
        if not paid and status == "refused" then
          local _, _, _, _, _, codNow = GetInboxHeaderInfo(index)
          paid = (tonumber(codNow) or 0) == 0
        end
        if paid then
          ns.Print(L()("MSG_COD_PAID", Helpers().FormatMoney(codBefore)))
        end
      end
      -- "busy" is a Postbox sequence already owning the channel; that run is
      -- writing its own status and must not be talked over.
      if status == "busy" then return end
      if status == "closed" then
        StatusMailboxClosed()
        return
      end
      if status == "timeout" then
        ns.Print(L()["MSG_MAIL_TIMEOUT"])
      elseif status == "refused" then
        if refused > 0 then
          -- The money and the other attachments did come through; only the
          -- takes the server declined are left behind.
          ns.Print(MailPartialMessage(refused, reason))
        else
          -- Nothing attributable to a particular take, but the mail is not
          -- empty. Say only that, without guessing why.
          ns.Print(L()["MSG_ITEM_NOT_COLLECTED"])
        end
        -- The domain has just recorded this mail as stuck, so the number in the
        -- title bar is out of date as of this instant.
        RefreshIdleSummary()
      end
      RequestRefresh(panel)
    end, confirmed)
  end)
end

-- A row in the read view is finished by definition -- read, no money, no
-- attachments -- so deleting it loses nothing and needs no confirmation. The
-- detail view's Delete can reach a mail that still holds something, and that
-- one confirms; see BuildDetail.
function DeleteOneMail(panel, index)
  if not index then return end
  Mail().DeleteMail(index, function(status)
    if status == "closed" then
      StatusMailboxClosed()
    elseif status == "timeout" then
      ns.Print(L()["MSG_MAIL_TIMEOUT"])
    end
    RequestRefresh(panel)
  end)
end

-------------------------------------------------------------
-- Bulk delete
--
-- Irreversible, and the previous build asked nothing at all.
--
-- It deletes what the done view LISTS, which is not the same thing as "every
-- mail with the read flag set": Mail().BuildDeleteQueue requires read AND no
-- money AND no attachments left, the same three tests IsReadPersistent makes. So
-- a mail the server refused -- read, but still holding the items it refused --
-- is never in the queue, and the button cannot reach anything that is still
-- waiting to be collected. That is why it could be renamed to match the done
-- view without touching what it does.
-------------------------------------------------------------

local function DeleteAllDone(panel)
  if not MailboxOpen() then
    StatusMailboxClosed()
    return
  end
  local queue = Mail().BuildDeleteQueue()
  if #queue == 0 then return end

  local counted = ns.Plural("COUNT_MAILS", #queue)
  local template = RawKey("CONFIRM_DELETE_ALL_DONE")
  local message = template and format(template, counted)
    or (L()["BTN_DELETE_ALL_DONE"] .. "\n" .. counted)

  -- What each queued index NAMES right now. Deleting is the irreversible one,
  -- and the inbox can reindex both while the dialog waits and between the
  -- sweep's own commands -- so the sweep verifies each index against this
  -- snapshot immediately before its command and skips any that moved.
  local expected = {}
  for i = 1, #queue do expected[queue[i]] = Fingerprint(queue[i]) end

  Confirm(POPUP_DELETE_ALL, DeleteLabel(), L()["COD_CONFIRM_CANCEL"],
    message, function()
      Mail().DeleteMails(queue, function(deleted, status)
        -- The mailbox can close between the confirmation and the answer, and
        -- the sweep stops where it is; saying so beats a dialog that dismisses
        -- itself over a half-deleted list.
        if status == "closed" then
          StatusMailboxClosed()
        elseif status == "timeout" then
          ns.Print(L()["MSG_MAIL_TIMEOUT"])
        end
        -- The receipt for an irreversible sweep: how many actually went, in
        -- chat, where it survives the window closing. Zero stays silent --
        -- every deletable mail moved before the answer, nothing happened.
        if (tonumber(deleted) or 0) > 0 then
          ns.Print(L()("MSG_DELETED_COUNT", ns.Plural("COUNT_MAILS", deleted)))
        end
        RequestRefresh(panel)
      end, expected)
    end)
end

-------------------------------------------------------------
-- The collection run
--
-- MailService owns the handshake for one mail. What a run adds is bookkeeping:
-- how many mails came through, how many attachments the server refused and why,
-- and -- the part that matters -- whether the run reached the end of its queue
-- or was stopped. Reporting "Done" for a stopped run is what made the old
-- silent-loss bug invisible, so the three outcomes are kept apart:
--
--   left > 0      the run was STOPPED and that many queued mails are still in
--                 the mailbox. stopReason says which guard stopped it.
--   refused > 0   the run reached the end of its queue, but the server would
--                 not hand over some attachments. Nothing was at risk.
--   neither       everything came through.
--
-- The run state lives here rather than on the shell's shared table: the shell
-- renders what this publishes and does not own it.
--
-- It also tallies MONEY, because a run is the only thing that knows which mails
-- it took. The banner above the list totals what is currently LISTED, which is a
-- different question with a different answer -- it changes as the player switches
-- segments and it says nothing about what this particular sweep brought in. The
-- two are the same arithmetic (MailEconomy) applied to two different sets, which
-- is why there is one function and not two definitions of "earned".
-------------------------------------------------------------

local Run = {
  active = false,
  panel = nil,
  queue = {},
  cursor = 0,
  current = nil,
  collected = 0,
  refused = 0,
  earned = 0,
  spent = 0,
  reason = nil,
  reasonMixed = false,
}

function CT.IsRunning()
  return Run.active and true or false
end

local function Remaining()
  local left = #Run.queue - Run.cursor
  if Run.current then left = left + 1 end
  return max(left, 0)
end

function CT.RefreshRunStatus()
  if not Run.active then return end
  StatusActivity(format(L()["STATUS_REMAINING"], Remaining()))
end

-- One refusal reason for a whole run. Two attachments can be refused for
-- different reasons, and quoting one would misdescribe the other, so a second
-- different reason falls back to the generic wording.
local function NoteReason(reason)
  if not reason or reason == "" or Run.reasonMixed then return end
  if Run.reason == nil then
    Run.reason = reason
  elseif Run.reason ~= reason then
    Run.reason, Run.reasonMixed = nil, true
  end
end

local function ResetRun()
  Run.active = false
  Run.current = nil
  Run.cursor = 0
  Clear(Run.queue)
  Run.collected = 0
  Run.refused = 0
  Run.earned = 0
  Run.spent = 0
  Run.reason = nil
  Run.reasonMixed = false
end

-- One line, at the end of a run, for the money that changed hands during it.
--
-- Both sides or one: a sweep of expired auctions earns nothing and a sweep of
-- purchases costs nothing, and "Earned 0g" is noise on either. Nothing is said
-- at all when neither side moved, which is the ordinary case for a mailbox full
-- of item mail -- a run that moved no gold should not announce that it did not.
--
-- Chat rather than the status line: the status line has one slot and a run's
-- OUTCOME owns it, and the outcome is the thing a player has to read.
local function ReportRunMoney(earned, spent)
  if earned <= 0 and spent <= 0 then return end

  local fmt = Helpers().FormatMoney
  local template
  if earned > 0 and spent > 0 then
    template = RawKey("MSG_RUN_EARNED_SPENT")
    if template then
      ns.Print(format(template, fmt(earned), fmt(spent)))
      return
    end
  end

  -- Either only one side moved, or the combined key is not in this locale yet.
  -- Two independent sentences say the same facts and cannot render as a broken
  -- template, so the fallback is the same shape as the normal path.
  if earned > 0 then
    local one = RawKey("MSG_RUN_EARNED")
    if one then ns.Print(format(one, fmt(earned))) end
  end
  if spent > 0 then
    local one = RawKey("MSG_RUN_SPENT")
    if one then ns.Print(format(one, fmt(spent))) end
  end
end

-------------------------------------------------------------
-- Run memory (.dev/SPEC-RunMemory.md): one small saved record per character
-- of the last run that ended badly, so the NEXT mailbox visit -- or the next
-- session -- opens with "last visit: N mails could not be taken" instead of
-- silence. A clean finish erases it; an inbox that emptied on its own erases
-- it at read time (Core/MailboxUI.lua, UpdateStatusSummary). Keyed by raw
-- GetRealmName()/UnitName like every other per-character table, stored at
-- the saved-variables root because profile values are boolean-only.
-------------------------------------------------------------

local function LastRunStore(create)
  local realm = GetRealmName()
  local name = UnitName("player")
  if type(realm) ~= "string" or realm == "" then return nil end
  if type(name) ~= "string" or name == "" then return nil end

  if create then
    local root = ns.Store.EnsurePath("lastRun")
    local byName = root[realm]
    if type(byName) ~= "table" then
      byName = {}
      root[realm] = byName
    end
    return byName, name
  end

  local root = ns.Store.Get("lastRun")
  local byName = type(root) == "table" and root[realm] or nil
  return type(byName) == "table" and byName or nil, name
end

function CT.GetLastRunRecord()
  local byName, name = LastRunStore(false)
  local record = byName and name and byName[name]
  if type(record) == "table" then return record end
  return nil
end

function CT.ClearLastRunRecord()
  local byName, name = LastRunStore(false)
  if byName and name then byName[name] = nil end
end

local function SaveLastRunRecord(collected, refused, left, reason, stopReason)
  local byName, name = LastRunStore(true)
  if not byName then return end
  local M = Mail()
  byName[name] = {
    at         = (type(time) == "function" and time()) or 0,
    collected  = collected,
    refused    = refused,
    left       = left,
    -- The game's own words, kept verbatim so the summary can attribute them
    -- the way every refusal message does.
    reason     = reason,
    stopReason = stopReason,
    -- The stuck registry's fingerprints ride along (capped in the service),
    -- so the next session can revive the per-mail markers, not just the
    -- sentence. See SeedStuckFromRecord below.
    stuck      = M and M.StuckSnapshot and M.StuckSnapshot() or nil,
  }
end

-- Run-memory bridge, called by the shell on mail open: the saved record's
-- fingerprints revive the live registry once per session, so the row
-- triangles and the Stuck count come back after a relog. After the seed the
-- live registry is the truth -- its entries re-validate against the live
-- inbox on every read, so anything resolved since simply never shows.
local recordSeeded = false

function CT.SeedStuckFromRecord()
  if recordSeeded then return end
  recordSeeded = true
  local record = CT.GetLastRunRecord()
  local M = Mail()
  if record and type(record.stuck) == "table" and M and M.SeedStuck then
    M.SeedStuck(record.stuck)
  end
end

-- The closing half of the bridge, called by the shell when the mailbox
-- shuts: the record's fingerprints re-sync to whatever the registry holds
-- NOW. This is what makes relog survival independent of HOW a refusal
-- happened -- a run that finished wrote its record, but a run the player
-- walked out of writes nothing, a clean sweep of one category erases the
-- record while another category's mail is still stuck, and a single-click
-- take never touches the record at all. One sync at the boundary covers
-- every path, and prunes fingerprints whose mail was freed since (they
-- would be filtered at read anyway; there is just no reason to save them).
function CT.SyncStuckRecord()
  local M = Mail()
  local snap = M and type(M.StuckSnapshot) == "function" and M.StuckSnapshot() or nil
  local record = CT.GetLastRunRecord()
  if snap then
    if record then
      -- The stored table itself: writing through updates SavedVariables.
      record.stuck = snap
    else
      -- No run wrote a record this visit (walk-away, or a single take's
      -- refusal). The counts claim nothing -- the fingerprints are the
      -- payload, and /postbox debug is the counts' only reader.
      SaveLastRunRecord(0, 0, 0, nil, nil)
    end
  elseif record then
    record.stuck = nil
  end
end

local function FinishRun(left, stopReason)
  local refused = Run.refused
  local collected = Run.collected
  local reason = Run.reason
  local earned, spent = Run.earned, Run.spent
  local panel = Run.panel
  ResetRun()

  -- A bad ending is written down for next visit; a clean one erases the note.
  if (tonumber(left) or 0) > 0 or (tonumber(refused) or 0) > 0 then
    SaveLastRunRecord(collected, refused, left, reason, stopReason)
  else
    CT.ClearLastRunRecord()
  end

  -- Every outcome leads with what came out: "Collected: 12" alone when the
  -- run was clean, with the problem appended after an em dash when it was
  -- not. The count is this session's report and deliberately does NOT
  -- persist -- a reopen shows only what is still actionable (the summary
  -- layer's Stuck line); what was collected is already in the bags.
  --
  -- Coloured PER SEGMENT with inline escapes, not one layer tone for the
  -- whole line: a green fact and an amber problem sharing one sentence must
  -- not both wear the problem's colour. The em dash carries no colour of
  -- its own, so it renders in the label's default -- a neutral divider.
  local theme = ns.Theme
  local function Tinted(token, text)
    if theme and theme.Colorize then return theme.Colorize(token, text) end
    return text
  end
  local got = tonumber(collected) or 0
  local JOIN = " \226\128\148 " -- em dash, spaced
  -- The green half leads only when there is anything green to say:
  -- "Collected: 0 — Stuck: 1" buries the one fact that matters under a
  -- zero. A clean run still reports its zero ("Collected: 0" on an empty
  -- category is a truthful nothing-to-do).
  local function WithCollected(problemText)
    if got > 0 then
      return Tinted("positive", format(L()["STATUS_COLLECTED"], got))
        .. JOIN .. problemText
    end
    return problemText
  end

  if left > 0 then
    StatusOutcome(WithCollected(
      Tinted("negative", format(L()["STATUS_INCOMPLETE"], left))))
    if stopReason == "bags" then
      ns.Print(format(L()["MSG_COLLECT_STOPPED_BAGS"], left))
    else
      ns.Print(format(L()["MSG_COLLECT_INCOMPLETE"], left))
    end
  elseif refused > 0 then
    StatusOutcome(WithCollected(
      Tinted("warning", format(L()["STATUS_PARTIAL"], refused))))
    if reason and reason ~= "" then
      ns.Print(L()("MSG_COLLECT_PARTIAL_REASON", collected, refused, reason))
    else
      ns.Print(L()("MSG_COLLECT_PARTIAL", collected, refused))
    end
  else
    StatusOutcome(Tinted("positive", format(L()["STATUS_COLLECTED"], got)))
  end

  -- After the outcome, never instead of it: a stopped run's "3 left" is the line
  -- the player has to act on, and the money is context under it.
  ReportRunMoney(earned, spent)

  RequestRefresh(panel)
  Mail().RequestInboxRefresh()
end

-- The mailbox closed under the run. What it had already taken is still taken, so
-- the money is reported here too -- a sweep that is interrupted halfway is
-- exactly when a player wants to know what did come through.
local function StopRun()
  local panel = Run.panel
  local earned, spent = Run.earned, Run.spent
  ResetRun()
  StatusMailboxClosed()
  ReportRunMoney(earned, spent)
  RequestRefresh(panel)
end

local function RunStep()
  if not Run.active then return end
  if not MailboxOpen() then
    -- The player walked away mid-run. Stop where we are and say so.
    StopRun()
    return
  end

  Run.cursor = Run.cursor + 1
  local index = Run.queue[Run.cursor]
  if not index then
    FinishRun(0)
    return
  end

  Run.current = index
  CT.RefreshRunStatus()
  RequestRefresh(Run.panel)

  -- Read BEFORE the take, because the take is what removes the evidence: a mail
  -- emptied of its money reports zero, and one emptied completely is deleted by
  -- the server and its index names a different mail entirely.
  local _, _, _, _, money = GetInboxHeaderInfo(index)
  local kind = Mail().ClassifyMail(index)
  local mailEarned, mailSpent = MailEconomy(index, kind, money)

  Mail().CollectMail(index, function(status, refused, reason)
    Run.current = nil
    RequestRefresh(Run.panel)

    if not Run.active then return end

    if status == "closed" then
      StopRun()
      return
    end

    if status == "busy" or status == "timeout" then
      -- Something is wrong with the run itself: the server stopped
      -- acknowledging commands, or the command channel was not ours to use at
      -- all. Either way the next command could be silently discarded. Stop, and
      -- count this mail plus everything still queued as left behind.
      FinishRun(Remaining() + 1, "timeout")
      return
    end

    -- Past the two statuses that mean "the take may not have happened", so the
    -- money did change hands -- including on a REFUSED take, where the server
    -- declines specific attachments and hands over the money and the rest
    -- regardless. Tallied before the bag-space guard below, which can end the
    -- run on this very mail.
    Run.earned = Run.earned + mailEarned
    Run.spent = Run.spent + mailSpent

    if status == "refused" then
      -- A fact about those items, not about the run: record them and keep
      -- going, because one item the player cannot hold must not block every
      -- other mail in the queue.
      Run.refused = Run.refused + (tonumber(refused) or 0)
      NoteReason(reason)
      -- One refusal does justify stopping: bags that filled on the way. Every
      -- further take would be refused too, and each mail walked past would be
      -- marked read for nothing.
      local free = Mail().FreeBagSlots()
      if free ~= nil and free <= 0 then
        -- The mail that was just refused still holds something, so it counts as
        -- left behind alongside everything still queued.
        FinishRun(Remaining() + 1, "bags")
        return
      end
    else
      Run.collected = Run.collected + 1
    end

    RunStep()
  end)
end

local function BeginRun(panel, queue)
  ResetRun()
  Run.active = true
  Run.panel = panel
  for i = 1, #queue do Run.queue[i] = queue[i] end
  -- Indices shift under a run; an overlay addressed by index cannot survive it.
  if panel.Detail then panel.Detail:Hide() end
  CT.RefreshRunStatus()
  RunStep()
end

-- Bag space is checked before a single mail is marked read. Collecting marks
-- every queued mail read, which resets its expiry clock and moves it out of the
-- actionable view, so doing that for mails whose attachments cannot physically
-- fit is the damaging part.
local function StartCategoryRun(panel, category)
  if Run.active or Mail().IsBusy() then return end
  if not MailboxOpen() then
    ns.Print(L()["ERR_OPEN_MAILBOX_LOOT"])
    return
  end

  -- Under a search the primary takes the mails on screen -- the list this
  -- panel last built -- and nothing else. The category buttons are withdrawn
  -- while a search is on, so `all` is the only category that can arrive here
  -- in that state.
  local queue, info
  if Selecting(panel) then
    -- The picked rows, and only those. The selection is spent by the run
    -- whatever comes of it: a refused run leaves ordinary uncollected mail,
    -- which the next press picks up as such.
    queue, info = Mail().BuildQueueFor(SelectionIndices(panel))
    ClearSelection(panel)
  elseif Searching(panel) then
    -- The rows on screen, narrowed again by the sweep's own category.
    queue, info = Mail().BuildQueueFor(panel._filtered, category)
  else
    queue, info = Mail().BuildQueue(category)
  end

  -- The inbox is still arriving: GetInboxNumItems reports 0 between MAIL_SHOW
  -- and the first MAIL_INBOX_UPDATE, and an index whose header has not landed
  -- is left out of the queue. Running now would sweep a truncated list and then
  -- report a clean finish over the mails it never saw.
  if info.unloaded > 0 or (info.numItems == 0 and info.totalItems > 0) then
    StatusOutcome(L()["STATUS_READY"])
    Mail().RequestInboxRefresh()
    RequestRefresh(panel)
    return
  end

  if #queue == 0 then
    StatusOutcome(L()["STATUS_DONE"], "positive")
    RequestRefresh(panel)
    return
  end

  local free = Mail().FreeBagSlots()
  if free ~= nil then
    local needed = Mail().QueueAttachmentSlots(queue)
    if needed > free then
      local fits = Mail().QueuePrefixThatFits(queue, free)
      if fits <= 0 then
        -- Nothing at all would fit. Refuse before anything is marked read.
        ShowNotice(L()("MSG_BAGS_FULL", needed, free))
        return
      end
      -- Snapshot what the dialog is about to describe, in queue order (highest
      -- inbox index first, so the remaining indices stay valid). The player can
      -- click a different category before answering, and this run must collect
      -- what the dialog said it would.
      local planned, prints = {}, {}
      for i = 1, fits do
        planned[i] = queue[i]
        prints[i] = Fingerprint(queue[i])
      end
      Confirm(POPUP_BAGSPACE, L()["BAGSPACE_CONFIRM_ACCEPT"], L()["COD_CONFIRM_CANCEL"],
        L()("MSG_BAGSPACE_PARTIAL", #queue, needed, free, fits),
        function()
          -- The dialog is not modal: rows can be clicked and the inbox can
          -- reindex while it waits, and then these indices name different
          -- mails -- including, possibly, C.O.D. mail the queue was built to
          -- exclude. Only the entries that still name the mail the dialog
          -- described are run; the dropped ones are ordinary uncollected mail
          -- the next run picks up at their new indices.
          local verified = {}
          for i = 1, #planned do
            if prints[i] and Fingerprint(planned[i]) == prints[i] then
              verified[#verified + 1] = planned[i]
            end
          end
          if #verified == 0 then
            RequestRefresh(panel)
            return
          end
          BeginRun(panel, verified)
        end)
      return
    end
  end

  BeginRun(panel, queue)
end

-------------------------------------------------------------
-- The detail view
--
-- An overlay over the collect screen: at the 480px window minimum there is no
-- room for a two-pane layout.
--
-- Three bands, bottom-anchored in this order: the action row, then the
-- attachment row, then the body. They are separate frames and the body's bottom
-- inset follows the two below it, which is what makes the Delete control
-- reachable -- in the previous build it sat at the bottom-left underneath the
-- first three attachment slots, which were created later at the same frame
-- level and therefore ate every click on it.
-------------------------------------------------------------

local DETAIL_ACTIONS = { "Back", "Collect", "Reply", "Return", "Delete" }

local function LayoutDetailActions(detail)
  local T = Th()
  local M = T.Metrics
  local shown = detail._shownActions
  Clear(shown)
  for i = 1, #DETAIL_ACTIONS do
    local button = detail[DETAIL_ACTIONS[i]]
    if button:IsShown() then shown[#shown + 1] = button end
  end
  if #shown == 0 then
    detail.ActionRow:SetHeight(1)
    return
  end

  local available = UsableWidth(detail.ActionRow, FALLBACK_PANEL_WIDTH - 2 * M.inset)
  -- Measured, longest-member-wins, and it wraps rather than overflowing: the
  -- four fixed-width buttons this replaces needed ~456px of a ~460px panel in
  -- English, and German "Zurueckschicken" did not fit its 100px allowance at
  -- all.
  local per, lines = T.LayoutRow(shown, available, {
    height = M.controlHeight,
    gap = M.tightGap,
    minWidth = M.buttonMinWidth,
  })
  local perLine = ceil(#shown / max(lines, 1))

  for i = 1, #shown do
    local line = floor((i - 1) / perLine)
    local column = (i - 1) - line * perLine
    shown[i]:ClearAllPoints()
    shown[i]:SetPoint("TOPLEFT", detail.ActionRow, "TOPLEFT",
      column * (per + M.tightGap), -line * (M.controlHeight + M.tightGap))
  end

  detail.ActionRow:SetHeight(lines * M.controlHeight + (lines - 1) * M.tightGap)
end

local function LayoutDetailSlots(detail)
  local T = Th()
  local M = T.Metrics
  -- The tiles in row order: the coin first when there is gold, then the
  -- item slots that hold something.
  local tiles = detail._tiles
  if not tiles then
    tiles = {}
    detail._tiles = tiles
  end
  Clear(tiles)
  if detail.MoneySlot and (detail._money or 0) > 0 then tiles[#tiles + 1] = detail.MoneySlot end
  for i = 1, detail._slotCount or 0 do tiles[#tiles + 1] = detail.Slots[i] end

  local count = #tiles
  if count <= 0 then
    detail.SlotRow:SetHeight(1)
    detail.SlotRow:Hide()
    return
  end

  local available = UsableWidth(detail.SlotRow, FALLBACK_PANEL_WIDTH - 2 * M.inset)
  local step = M.slotSize + M.tightGap
  local perLine = max(1, floor((available + M.tightGap) / step))
  local lines = ceil(count / perLine)

  for i = 1, count do
    local slot = tiles[i]
    local line = floor((i - 1) / perLine)
    local column = (i - 1) - line * perLine
    slot:ClearAllPoints()
    slot:SetPoint("TOPLEFT", detail.SlotRow, "TOPLEFT", column * step, -line * step)
  end

  detail.SlotRow:SetHeight(lines * step - M.tightGap)
  detail.SlotRow:Show()
end

-- The header is two stacked strings beside a fixed-size icon, so where the
-- metadata line starts is the taller of the two -- which no anchor can express.
-- Recomputed whenever the text or the width changes; the subject wraps, so its
-- height is a function of both.
local function LayoutDetailHeader(detail)
  local T = Th()
  local M = T.Metrics
  local headerHeight = (detail.Sender:GetStringHeight() or 0)
    + M.tightGap + (detail.Subject:GetStringHeight() or 0)
  detail.Info:ClearAllPoints()
  detail.Info:SetPoint("TOPLEFT", detail, "TOPLEFT", M.inset, -(M.inset + headerHeight + M.gap))
  detail.Info:SetPoint("RIGHT", detail, "RIGHT", -M.inset, 0)
end

local function LayoutDetail(detail)
  LayoutDetailActions(detail)
  LayoutDetailSlots(detail)
  LayoutDetailHeader(detail)
end

-- Forward declared: a refused take has to repaint the metadata line, and the
-- painter is defined further down beside the rest of the overlay's content.
local PaintDetailContent

local function TakeOneAttachment(detail, slot)
  -- LiveIndex, not detail.mailIndex: a take is a command, and it may only be
  -- aimed at an index that still names the mail this overlay is showing.
  --
  -- The itemLink guard carries the case where no fetch landed. A mail's links
  -- are not loaded until its body is fetched, and the fetch declines while
  -- another sequence owns the command channel -- so in an overlay opened at that
  -- moment the slots show what the client knows and stay inert, rather than
  -- firing a take the service would answer "collected" to and blanking a slot
  -- whose item never moved.
  local index, slotIndex = LiveIndex(detail), slot.slotIndex
  if not index or not slotIndex or not slot.itemLink then return end

  -- The FIRST take from a C.O.D. mail pays the whole amount, so the same
  -- confirmation the Collect button gets stands in front of a slot click too.
  -- For everything else ConfirmCOD calls straight through. Its accept
  -- re-verifies the mail's identity; the index is re-derived after the wait
  -- because the dialog is not modal and the overlay's mail can move under it.
  ConfirmCOD(index, function()
    index = LiveIndex(detail)
    if not index then return end
    local _, _, _, _, _, codBefore = GetInboxHeaderInfo(index)
    codBefore = tonumber(codBefore) or 0

    Mail().TakeAttachment(index, slotIndex, function(status, refused, reason)
      -- The slot is cleared only once the item has actually left the mailbox.
      -- Blanking it on a timeout, or on a take the server refused, would tell
      -- the player it was collected while it is still sitting there. It stays
      -- clickable, so a retry is their decision rather than an automatic one.
      if status == "busy" then return end
      if status == "closed" then
        StatusMailboxClosed()
        return
      end
      if status == "timeout" then
        ns.Print(L()["MSG_MAIL_TIMEOUT"])
        return
      end
      if status == "refused" or (tonumber(refused) or 0) > 0 then
        ns.Print(ItemRefusedMessage(reason))
        -- The domain has just recorded this mail as stuck, and the overlay is
        -- still the screen the player is looking at. Repainting puts the
        -- reason in the metadata line where the click was, instead of only in
        -- a chat message and on a row hidden behind this frame.
        PaintDetailContent(detail, index)
        LayoutDetail(detail)
        RefreshIdleSummary()
        return
      end

      -- The take landed, so a confirmed C.O.D. was just paid: say so in the
      -- game's chat, in gold, where the player can check it against the bill.
      if codBefore > 0 then
        ns.Print(L()("MSG_COD_PAID", Helpers().FormatMoney(codBefore)))
      end

      -- Taking one attachment can compact the others downwards, so never
      -- assume the slot is now empty: re-read it.
      local link = GetInboxItemLink(index, slotIndex)
      if link then
        local _, _, texture, count = GetInboxItem(index, slotIndex)
        if texture then slot.Icon:SetTexture(texture) end
        slot.Count:SetText((tonumber(count) or 0) > 1 and tostring(count) or "")
        slot.itemLink = link
      else
        slot.Icon:Hide()
        slot.Count:SetText("")
        slot.itemLink = nil
        slot:Hide()
      end
      RequestRefresh(detail._panel)
    end, { allowCOD = true })
  end)
end

local function BuildDetailSlot(detail, i)
  local T = Th()
  local slot = CreateFrame("Button", nil, detail.SlotRow, "BackdropTemplate")
  slot:SetSize(T.Metrics.slotSize, T.Metrics.slotSize)
  slot.slotIndex = i

  -- The native empty-slot art IS the look. Nothing opaque goes over it: the
  -- previous build laid this down, shaded it, then applied a full-alpha card
  -- surface above both, so the art was dead pixels.
  local art = slot:CreateTexture(nil, "BACKGROUND")
  art:SetAllPoints()
  art:SetTexture(EMPTY_SLOT_ART)
  art:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  slot.Icon = slot:CreateTexture(nil, "ARTWORK")
  slot.Icon:SetAllPoints()
  slot.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  slot.Icon:Hide()

  slot.Count = T.CreateText(slot, "numberSmall", "OVERLAY")
  slot.Count:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -2, 2)

  -- The client's own square slot highlight, additively blended -- the same one
  -- the compose screen's attachment slots use, so the two grids of item slots
  -- hover identically. It was a flat 15% white wash: a colour this file chose
  -- for itself, and the last one in it.
  local highlight = slot:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetAllPoints()
  highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
  highlight:SetBlendMode("ADD")

  -- The card border and nothing else: no fill, no grain, and NOT tagged as a
  -- themed panel -- an item slot is not a panel and both skins would paint over
  -- its art if it claimed to be one.
  T.ApplySlot(slot)

  -- SetInboxItem rather than SetHyperlink on the stored link: the link is nil
  -- until the mail's body has been fetched, so a link-based tooltip is dead on
  -- exactly the mails a preview exists for. Addressed by mail and slot, and the
  -- mail is re-verified on every hover -- indices slide down whenever a mail
  -- below this one is emptied.
  -- No "does this slot hold anything" guard: a slot is shown only while it does,
  -- and a hidden frame receives no OnEnter.
  slot:SetScript("OnEnter", function(self)
    local index = LiveIndex(detail)
    if not index then return end
    ShowAttachmentTooltip(self, index, self.slotIndex)
  end)
  slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
  slot:SetScript("OnClick", function(self) TakeOneAttachment(detail, self) end)
  slot:Hide()

  return slot
end

local function HideDetail(panel)
  if panel.Detail then panel.Detail:Hide() end
end

-- The detail is addressed by inbox index, and an index stops naming its mail
-- the moment the mail is emptied. Rather than closing on every refresh -- which
-- used to need a timer, because reading a mail marks it read and refreshes the
-- list underneath the thing just opened -- the overlay closes only when its
-- mail has actually gone, or when a run is shifting indices wholesale.
function CloseDetailIfStale(panel)
  local detail = panel.Detail
  if not detail or not detail:IsShown() then return end
  if Run.active then
    detail:Hide()
    return
  end
  if not LiveIndex(detail) then detail:Hide() end
end

-------------------------------------------------------------
-- The detail view :: the body
--
-- Opening a mail shows the mail, all of it, immediately. There is no longer a
-- "Show message" gate in front of the body of an unread one.
--
-- The gate was never about the text. GetInboxText fetches the body AND marks the
-- mail read, and while the screen's headline numbers counted the READ FLAG that
-- meant a peek silently moved a number the player was not looking at -- so the
-- cost had to be stated and consented to. The numbers count CONTENT now (see
-- "One taxonomy" at the top of this file): reading a mail moves nothing it was
-- not already true of, the row's unread dot goes out on the next refresh, and
-- that is the whole of the effect. Which is exactly how every mail client the
-- player has ever used behaves.
--
-- `_bodyFetched` survives, because it is not friction: Collect's `skipFetch` is
-- a claim that this mail's attachment links are already loaded, and only a fetch
-- that actually WENT OUT can make it. Mail().FetchMailBody declines while
-- another sequence owns the command channel, so the flag follows what happened
-- rather than what was intended.
-------------------------------------------------------------

-- The body area, showing whatever the fetch returned. nil is "no fetch went
-- out"; "" is "the mail genuinely has no text". Both read the same to the
-- player, and only the first leaves `skipFetch` unclaimable.
local function ShowBody(detail, text)
  detail._bodyFetched = (text ~= nil)
  detail.BodyText:SetText((text and text ~= "") and text or L()["DETAIL_NO_BODY"])
  detail.BodyChild:SetHeight(max(detail.BodyText:GetStringHeight() or 10, 10))
  detail.BodyScroll:SetVerticalScroll(0)
  detail.BodyScroll:Show()
end

-------------------------------------------------------------
-- The detail view :: its own ground
--
-- One mail, read on its own. Nothing behind it may show through -- not a row of
-- the list, not the segment captions it covers, not the totals banner. Two
-- separate things were letting them:
--
--   THE SURFACE FOLLOWED THE WINDOW'S OPACITY. The overlay is a card, and a
--   card is part of the window's surface -- which under a host-UI skin is
--   painted at whatever background opacity the user set, so at 70% the list
--   underneath was legible THROUGH the mail's own header. Theme's popup floor
--   exists for exactly this, but it is applied to cards that FLOAT (toplevel or
--   raised out of their parent's strata) and this one deliberately does not
--   float: it is a panel-sized overlay, not a dialog. So it lays its own ground.
--
--   THE LIST WAS STILL THERE. Even an all-but-opaque ground composites what is
--   under it, and a list of rows is high-contrast text. It is hidden outright
--   while the overlay is up -- which is both cheaper and more honest than
--   trimming the last few per cent of alpha out of a stack of frames.
--
-- The ground is a texture on a HOLDER FRAME one level below the overlay, and
-- that is not tidiness. A host skin's first act on one of our panels is to fade
-- every texture region the frame owns to alpha 0 so that its own art is what
-- shows (Core/Skin_EllesmereUI.lua, ShimFadeRegions); a region of a CHILD frame
-- is not a region of the overlay, so the sweep never reaches it, and a child one
-- level down draws beneath everything the skin then paints on top. Same
-- construction as Core/Theme.lua's popup floor, for the same reason.
-------------------------------------------------------------

-- Above the popup floor's 0.95: this one covers a dense list rather than a
-- couple of controls, and the last two per cent are the difference between "very
-- faint" and "not there".
local DETAIL_GROUND_ALPHA = 0.98

-- The host's own window fill where a skin publishes one, so the ground is the
-- colour that skin would have used rather than a Postbox grey under its art.
-- Re-resolved on every paint: EllesmereUI's baseline moves on a profile switch.
local function DetailGroundColor()
  local skin = ns.Skin
  if skin and type(skin.GetHostBaseline) == "function" then
    local ok, r, g, b = pcall(skin.GetHostBaseline)
    if ok and type(r) == "number" and type(g) == "number" and type(b) == "number" then
      return r, g, b
    end
  end
  local fill = Th().Colors.surface
  return fill[1], fill[2], fill[3]
end

local function PaintDetailGround(detail)
  local art = detail and detail.__pbGround
  if not art then return end
  local r, g, b = DetailGroundColor()
  art:SetColorTexture(r, g, b, DETAIL_GROUND_ALPHA)
  -- Region alpha and colour alpha MULTIPLY, so the line above is only half of
  -- it: anything that faded this region would otherwise survive the repaint.
  art:SetAlpha(1)
end

local function BuildDetailGround(detail)
  local level = tonumber((detail.GetFrameLevel and detail:GetFrameLevel())) or 1
  local holder = CreateFrame("Frame", nil, detail)
  holder:SetAllPoints(detail)
  holder:SetFrameLevel(max(0, level - 1))
  detail.__pbGroundHolder = holder

  detail.__pbGround = holder:CreateTexture(nil, "BACKGROUND", nil, -8)
  detail.__pbGround:SetAllPoints(holder)
  PaintDetailGround(detail)
end

local function BuildDetail(panel)
  local T = Th()
  local M = T.Metrics

  local detail = CreateFrame("Frame", nil, panel, "BackdropTemplate")
  -- Inset like the list it covers: the same margin the top row, the list
  -- area and the footer keep from the panel's edges, so the overlay is
  -- exactly as wide as the tabs above it rather than running to the window.
  detail:SetPoint("TOPLEFT", panel, "TOPLEFT", M.inset, -M.inset)
  detail:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -M.inset, M.inset)
  detail:SetFrameLevel(panel:GetFrameLevel() + 20)
  detail:EnableMouse(true)
  T.ApplyCard(detail)
  BuildDetailGround(detail)
  detail._panel = panel
  detail._shownActions = {}
  detail._infoParts = {}
  detail.Slots = {}

  -- Bottom band 1: the actions. Anchored to the panel's own bottom edge, so
  -- nothing created later can be drawn over them.
  detail.ActionRow = CreateFrame("Frame", nil, detail)
  detail.ActionRow:SetPoint("BOTTOMLEFT", detail, "BOTTOMLEFT", M.inset, M.inset)
  detail.ActionRow:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -M.inset, M.inset)
  detail.ActionRow:SetHeight(M.controlHeight)

  -- Bottom band 2: the attachments, above the actions and never overlapping.
  detail.SlotRow = CreateFrame("Frame", nil, detail)
  detail.SlotRow:SetPoint("BOTTOMLEFT", detail.ActionRow, "TOPLEFT", 0, M.gap)
  detail.SlotRow:SetPoint("BOTTOMRIGHT", detail.ActionRow, "TOPRIGHT", 0, M.gap)
  detail.SlotRow:SetHeight(M.slotSize)

  for i = 1, Mail().MAX_ATTACHMENTS do
    detail.Slots[i] = BuildDetailSlot(detail, i)
  end

  -- The coin tile: gold in a mail, shown where the items are and taken the
  -- way an item is. It used to be a number in the metadata line only, and
  -- a sale's proceeds read as a fact about the mail rather than as the
  -- thing there was to collect from it. First in the row, before any item.
  local money = CreateFrame("Button", nil, detail.SlotRow, "BackdropTemplate")
  money:SetSize(M.slotSize, M.slotSize)
  local moneyArt = money:CreateTexture(nil, "BACKGROUND")
  moneyArt:SetAllPoints()
  moneyArt:SetTexture(EMPTY_SLOT_ART)
  moneyArt:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  money.Icon = money:CreateTexture(nil, "ARTWORK")
  money.Icon:SetAllPoints()
  money.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  money.Icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
  money.Count = T.CreateText(money, "numberSmall", "OVERLAY")
  money.Count:SetPoint("BOTTOMRIGHT", money, "BOTTOMRIGHT", -2, 2)
  local moneyHighlight = money:CreateTexture(nil, "HIGHLIGHT")
  moneyHighlight:SetAllPoints()
  moneyHighlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
  moneyHighlight:SetBlendMode("ADD")
  T.ApplySlot(money)
  money:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L()["LABEL_GOLD"] .. Helpers().FormatMoney(detail._money or 0), 1, 1, 1)
    GameTooltip:Show()
  end)
  money:SetScript("OnLeave", function() GameTooltip:Hide() end)
  money:SetScript("OnClick", function()
    local index = LiveIndex(detail)
    if not index then return end
    Mail().TakeMoney(index, function(status)
      if status == "busy" then return end
      if status == "closed" then
        StatusMailboxClosed()
        return
      end
      if status == "timeout" then
        ns.Print(L()["MSG_MAIL_TIMEOUT"])
        return
      end
      -- Re-read rather than assumed: the header says whether the gold went.
      local live = LiveIndex(detail)
      if live then
        PaintDetailContent(detail, live)
        LayoutDetail(detail)
      end
      RequestRefresh(panel)
    end)
  end)
  money:Hide()
  detail.MoneySlot = money

  for i = 1, #DETAIL_ACTIONS do
    detail[DETAIL_ACTIONS[i]] = T.CreateButton(nil, detail.ActionRow)
  end
  detail.Back:SetText(L()["BTN_BACK"])
  detail.Collect:SetText(L()["BTN_TAKE_ALL"])
  detail.Reply:SetText(L()["BTN_REPLY"])
  detail.Return:SetText(L()["BTN_RETURN"])
  detail.Delete:SetText(DeleteLabel())

  detail.Back:SetScript("OnClick", function() detail:Hide() end)

  detail.Collect:SetScript("OnClick", function()
    local index = LiveIndex(detail)
    if not index then return end
    detail:Hide()
    -- skipFetch is a claim that this mail's attachment links are already loaded,
    -- and only a fetch that actually went out can make it. Opening the overlay
    -- asks for one, but the service declines while another sequence owns the
    -- command channel -- so the flag follows what happened rather than what was
    -- asked for. MailService re-checks it anyway; a caller should still not be
    -- asserting something it does not know.
    CollectSingleMail(panel, index, { skipFetch = detail._bodyFetched and true or false })
  end)

  detail.Reply:SetScript("OnClick", function()
    -- Verified like the rest: this reads a sender off an index, and addressing a
    -- reply to whoever slid into that slot is the one way this button can be
    -- quietly wrong.
    local index = LiveIndex(detail)
    if not index then return end
    local _, _, sender = GetInboxHeaderInfo(index)
    detail:Hide()
    CT.RequestReply(sender, detail.Subject:GetText() or "")
  end)

  detail.Return:SetScript("OnClick", function()
    -- Verified: returning a mail is irreversible and reindexes the inbox, so it
    -- may only ever be aimed at an index that still names this mail.
    local index = LiveIndex(detail)
    if not index then return end
    detail:Hide()
    Mail().ReturnMail(index, function(status)
      if status == "closed" then
        StatusMailboxClosed()
      elseif status == "timeout" then
        ns.Print(L()["MSG_MAIL_TIMEOUT"])
      end
      RequestRefresh(panel)
    end)
  end)

  detail.Delete:SetScript("OnClick", function()
    local index = LiveIndex(detail)
    if not index then return end
    -- Delete is offered on read mail, and a read mail can still hold items when
    -- the bags filled mid-run. Deleting that loses them, so it confirms -- in
    -- the client's own words where it has them.
    if Mail().HasContent(index) then
      -- The client's own wording where it has one -- it is already translated
      -- for every locale and says exactly the right thing.
      local native = _G["DELETE_MAIL_CONFIRMATION"]
      local message = (type(native) == "string" and native ~= "" and native)
        or RawKey("CONFIRM_DELETE_MAIL")
        or DeleteLabel()
      Confirm(POPUP_DELETE_ONE, DeleteLabel(), L()["COD_CONFIRM_CANCEL"],
        message, function()
          detail:Hide()
          -- Re-verified on the way out of the dialog: the inbox can reindex
          -- between the question and the answer, and this is the irreversible
          -- one.
          DeleteOneMail(panel, LiveIndex(detail))
        end)
      return
    end
    detail:Hide()
    DeleteOneMail(panel, index)
  end)

  -- Header: sender, subject, then the metadata line, flush with the panel's
  -- left edge. There used to be a 36px icon box at the top-left with the
  -- text hanging off its right; the same icon sits in the attachment row
  -- below, so up here it was a square of nothing that looked like a slot
  -- waiting for an item.
  detail.Sender = T.CreateText(detail, "heading")
  detail.Sender:SetPoint("TOPLEFT", detail, "TOPLEFT", M.inset, -M.inset)
  detail.Sender:SetPoint("RIGHT", detail, "RIGHT", -M.inset, 0)
  detail.Sender:SetJustifyH("LEFT")
  detail.Sender:SetWordWrap(false)

  -- The full panel width. It used to stop 148px short, pinned to the left edge
  -- of a button sitting 22px higher that could not have collided with it, so a
  -- long auction subject wrapped into the metadata line below.
  detail.Subject = T.CreateText(detail, "body")
  detail.Subject:SetPoint("TOPLEFT", detail.Sender, "BOTTOMLEFT", 0, -M.tightGap)
  detail.Subject:SetPoint("RIGHT", detail, "RIGHT", -M.inset, 0)
  detail.Subject:SetJustifyH("LEFT")
  detail.Subject:SetWordWrap(true)

  detail.Info = T.CreateText(detail, "secondary")
  detail.Info:SetJustifyH("LEFT")
  detail.Info:SetWordWrap(true)

  -- Body, between the header and the two bottom bands, on its own surface:
  -- the list surface the mail rows sit on, so the message reads as content
  -- inside the card and the header as the card's own chrome. The scroll
  -- frame sits inside it with the rows' padding, and its bar is pinned to
  -- the surface's edge and hidden until the text needs it.
  detail.BodyCard = CreateFrame("Frame", nil, detail, "BackdropTemplate")
  detail.BodyCard:SetPoint("TOPLEFT", detail.Info, "BOTTOMLEFT", 0, -M.gap)
  detail.BodyCard:SetPoint("RIGHT", detail, "RIGHT", -M.inset, 0)
  detail.BodyCard:SetPoint("BOTTOM", detail.SlotRow, "TOP", 0, M.gap)
  T.ApplyList(detail.BodyCard)

  detail.BodyScroll = CreateFrame("ScrollFrame", nil, detail.BodyCard, "UIPanelScrollFrameTemplate")
  detail.BodyScroll:SetPoint("TOPLEFT", detail.BodyCard, "TOPLEFT", M.gap, -M.gap)
  detail.BodyScroll:SetPoint("BOTTOMRIGHT", detail.BodyCard, "BOTTOMRIGHT", -M.scrollGutter, M.gap)
  PinScrollBar(detail.BodyScroll, detail.BodyCard)

  detail.BodyChild = CreateFrame("Frame", nil, detail.BodyScroll)
  detail.BodyChild:SetSize(FALLBACK_PANEL_WIDTH, 10)
  detail.BodyScroll:SetScrollChild(detail.BodyChild)

  detail.BodyText = T.CreateText(detail.BodyChild, "bodySmall")
  detail.BodyText:SetPoint("TOPLEFT", detail.BodyChild, "TOPLEFT", 0, 0)
  detail.BodyText:SetJustifyH("LEFT")
  detail.BodyText:SetWordWrap(true)
  detail.BodyText:SetWidth(FALLBACK_PANEL_WIDTH)

  detail.BodyScroll:HookScript("OnSizeChanged", function(_, width)
    if not width or width <= 10 then return end
    detail.BodyChild:SetWidth(width)
    detail.BodyText:SetWidth(width)
    detail.BodyChild:SetHeight(max(detail.BodyText:GetStringHeight() or 10, 10))
  end)

  detail:SetScript("OnSizeChanged", function(self) LayoutDetail(self) end)

  -- The list goes away while one mail is being read, and comes back whichever
  -- way the overlay closed -- Back, Collect, Return, Delete, a stale index, a
  -- run starting, or the whole panel being hidden underneath it. Driven from the
  -- overlay's own visibility rather than from each of those call sites, because
  -- there are seven of them and a missed one would leave the screen empty.
  --
  -- The refresh running underneath is unaffected: CT.RefreshMailList gates on
  -- the PANEL being shown, not the list container, and a hidden frame keeps its
  -- rect -- so the virtualiser's viewport maths, the scroll clamp and the row
  -- binds all still produce the list that is waiting when it reappears.
  detail:SetScript("OnShow", function(self)
    PaintDetailGround(self)
    panel.MailListArea:Hide()
  end)
  detail:SetScript("OnHide", function() panel.MailListArea:Show() end)
  detail:Hide()

  panel.Detail = detail
end

-- Builds the metadata line. One pass, one table, reused: this is the densest
-- string in the addon and it is rebuilt whenever the overlay opens.
local function DetailInfoText(detail, index, kind, hasCOD)
  local T = Th()
  local fmt = Helpers().FormatMoney
  local labels = Labels()
  local _, _, _, _, money, cod, daysLeft, itemCount, wasRead, wasReturned = GetInboxHeaderInfo(index)

  local parts = detail._infoParts
  Clear(parts)

  local moneyValue = tonumber(money) or 0
  local codValue = tonumber(cod) or 0
  if moneyValue > 0 then parts[#parts + 1] = L()["LABEL_GOLD"] .. fmt(moneyValue) end
  if hasCOD and codValue > 0 then
    parts[#parts + 1] = T.Colorize("negative", L()["LABEL_COD"] .. fmt(codValue))
  end
  parts[#parts + 1] = labels[kind] or kind
  itemCount = tonumber(itemCount) or 0
  if itemCount > 0 then parts[#parts + 1] = ns.Plural("COUNT_ITEMS", itemCount) end
  parts[#parts + 1] = wasRead and L()["STATUS_READ"] or L()["STATUS_UNREAD"]
  if wasReturned then parts[#parts + 1] = L()["STATUS_RETURNED"] end
  if daysLeft then parts[#parts + 1] = format(L()["DETAIL_EXPIRES"], daysLeft) end

  AppendInvoiceFigures(parts, index, true)

  -- Last, and in the warning tone: everything above describes what the mail IS,
  -- and this says why it is still here. The line wraps, so a long quotation from
  -- the server pushes the body down rather than being cut off -- which is the
  -- right trade for the one sentence that explains the whole screen.
  local stuckReason = Mail().StuckReason(index)
  if stuckReason then
    parts[#parts + 1] = T.Colorize("warning", StuckLine(stuckReason))
  end

  return concat(parts, "  |  ")
end

-- Everything the overlay shows EXCEPT the body, from data the client already
-- holds. Split out because it has two callers: opening the overlay -- where it
-- runs AFTER the body fetch, which is what makes the read status, the icon and
-- the attachment links it reads the current ones -- and a refused take, which
-- has to put the reason in the metadata line under the click that produced it.
function PaintDetailContent(detail, index)
  local _, _, sender, subject, money, cod, _, itemCount, wasRead = GetInboxHeaderInfo(index)
  local kind, hasCOD = Mail().ClassifyMail(index)
  local codValue = tonumber(cod) or 0
  local isCOD = hasCOD and codValue > 0
  local hasContent = (tonumber(money) or 0) > 0 or (tonumber(itemCount) or 0) > 0

  detail.Sender:SetText(sender or L()["SENDER_UNKNOWN"])
  detail.Subject:SetText(Helpers().ShortSubject(subject or ""))
  detail.Info:SetText(DetailInfoText(detail, index, kind, hasCOD))

  -- Reply exists to hand a C.O.D. mail back. Return is offered wherever the
  -- client would offer it in place of Delete: a mail from a player that still
  -- holds something -- the client's InboxItemCanDelete answers false for
  -- exactly those, and its own OpenMail frame swaps its Delete button for
  -- Return on the same test. Once a mail has been emptied there is nothing to
  -- return, and a system mail (auction house, quest reward) cannot be. Delete
  -- is never offered on a C.O.D. mail, nor on one the client says to return.
  local canDelete = true
  if type(InboxItemCanDelete) == "function" then
    local ok, answer = pcall(InboxItemCanDelete, index)
    if ok then canDelete = answer and true or false end
  end
  detail.Reply:SetShown(isCOD and hasContent)
  detail.Return:SetShown(hasContent and (isCOD or not canDelete))
  detail.Delete:SetShown(wasRead and not isCOD and canDelete)

  local shownSlots = 0
  for i = 1, Mail().MAX_ATTACHMENTS do
    local slot = detail.Slots[i]
    local _, _, texture, count = GetInboxItem(index, i)
    if texture then
      shownSlots = i
      slot.Icon:SetTexture(texture)
      slot.Icon:Show()
      slot.Count:SetText((tonumber(count) or 0) > 1 and tostring(count) or "")
      -- nil where no fetch has landed for this mail -- the channel was busy when
      -- the overlay opened. The slot still shows the item and still raises its
      -- tooltip (SetInboxItem needs no link); what the link decides is whether
      -- clicking it can take anything -- see TakeOneAttachment.
      slot.itemLink = GetInboxItemLink(index, i)
      slot:Show()
    else
      slot.Icon:Hide()
      slot.Count:SetText("")
      slot.itemLink = nil
      slot:Hide()
    end
  end
  detail._slotCount = shownSlots

  -- The coin tile, with the amount's leading denomination on it ("25g");
  -- the whole sum is in its tooltip and in the metadata line above.
  local moneyValue = tonumber(money) or 0
  detail._money = moneyValue
  if detail.MoneySlot then
    if moneyValue > 0 then
      local text = Helpers().FormatMoney(moneyValue)
      detail.MoneySlot.Count:SetText(text:match("^%S+") or text)
      detail.MoneySlot:Show()
    else
      detail.MoneySlot:Hide()
    end
  end
end

function ShowDetail(panel, index)
  local detail = panel.Detail
  if not detail then return end

  local fingerprint = Fingerprint(index)
  if not fingerprint then return end

  detail.mailIndex = index
  detail.fingerprint = fingerprint

  -- Read BEFORE the fetch, because the fetch is what changes it, and it is the
  -- one thing that decides whether the list underneath needs rebuilding at all.
  local _, _, _, _, _, _, _, _, wasRead = GetInboxHeaderInfo(index)

  -- THE BODY FIRST, and everything else painted from what the fetch left behind.
  -- The fetch marks the mail read, loads its attachment links and can turn a
  -- generic package icon into the first attachment's own art -- so a paint taken
  -- before it would say "Unread" beside a mail that no longer is, and leave every
  -- slot inert (TakeOneAttachment needs the link). Run.active is re-checked here
  -- rather than trusted to the row gate, because this is where the command would
  -- actually be issued, and a fetch mid-run would be read by the run's own
  -- sequence as its acknowledgement.
  ShowBody(detail, (not Run.active) and Mail().FetchMailBody(index) or nil)
  PaintDetailContent(detail, index)

  LayoutDetail(detail)
  detail:Show()

  -- Opening an unread mail read it, so the row this came from is now wrong: its
  -- unread dot, and -- for a mail that held nothing else -- which of the two
  -- views it belongs in. Nothing changed for a mail that was already read, and a
  -- rebuild of a list currently hidden behind this overlay is not free.
  --
  -- Coalesced, and it cannot close the overlay: the fingerprint is sender +
  -- subject + C.O.D., none of which reading alters.
  if not wasRead then RequestRefresh(panel) end
end

-------------------------------------------------------------
-- Reply
--
-- The compose screen owns its own fields. Ask it to prepare a reply where it
-- offers an entry point, and fall back to writing the boxes directly where it
-- does not.
-------------------------------------------------------------

function CT.RequestReply(recipient, originalSubject)
  local UI = ns.MailboxUI
  if not UI or not UI._frame then return end

  local prefix = RawKey("REPLY_PREFIX")
  local subject
  if originalSubject and originalSubject ~= "" then
    subject = prefix and format(prefix, originalSubject) or ("Re: " .. originalSubject)
  else
    subject = L()["DEFAULT_SUBJECT"]
  end

  if type(UI.SelectTab) == "function" then UI.SelectTab("send") end

  local Send = ns.SendTab
  if Send and type(Send.PrepareReply) == "function" then
    Send.PrepareReply(recipient, subject)
    return
  end

  local panel = UI._frame.Tabs and UI._frame.Tabs.send
  if not panel or not panel.ToBox then return end
  panel.ToBox:SetText(recipient or "")
  panel.ToBox:SetCursorPosition(0)
  if panel.SubjectBox then
    panel.SubjectBox:SetText(subject)
    panel.SubjectBox:SetCursorPosition(0)
  end
  if panel.BodyBox then
    panel.BodyBox:SetText(L()["DEFAULT_BODY"])
    panel.BodyBox:SetCursorPosition(0)
  end
end

-------------------------------------------------------------
-- The category grid
--
-- Six buttons: the full-width primary, then five tiling in two rows of three.
-- Column edges are derived from the usable width so the right-hand column lands
-- exactly on the grid edge -- flooring one button width instead discards up to
-- a pixel per column and the right margin visibly shifts as the window resizes.
-------------------------------------------------------------

local function LayoutGrid(panel)
  local grid = panel.Grid
  if not grid or not panel._gridButtons then return end
  local T = Th()
  local M = T.Metrics
  local width = UsableWidth(grid, PanelWidth(panel) - 2 * M.inset)
  local buttons = panel._gridButtons

  buttons[1]:ClearAllPoints()
  buttons[1]:SetSize(width, GRID_PRIMARY_HEIGHT)
  buttons[1]:SetPoint("TOPLEFT", grid, "TOPLEFT", 0, 0)

  -- The five sweeps are laid out whether or not they are shown: the option
  -- can flip while the window is open, and a hidden button that is already in
  -- its column simply appears. A live search withdraws them too, and gives
  -- the primary its narrower name.
  -- Neither a search nor a selection withdraws the sweeps. Under a search
  -- each sweep acts on the rows on screen of its own kind -- "All sold"
  -- over a search for one seller is the sold mail from that seller -- so
  -- they still mean what they say; and a footer that changed shape under a
  -- keystroke or a shift-click read as the screen moving for no reason, and
  -- pushed the list a half-row off its whole-row floor.
  local extras = ShowCategoryButtons()
  if Selecting(panel) then
    buttons[1].caption = L()("CAT_SELECTED", SelectionCount(panel))
  elseif Searching(panel) then
    buttons[1].caption = L()["CAT_SHOWN"]
  else
    buttons[1].caption = Labels().all or "all"
  end
  local columns = T.ColumnEdges(width, GRID_COLUMNS, M.gap, panel._gridColumns)
  for i = 2, #buttons do
    local slot = i - 2
    local line = floor(slot / GRID_COLUMNS)
    local column = slot - line * GRID_COLUMNS
    local edge = columns[column + 1]
    buttons[i]:ClearAllPoints()
    buttons[i]:SetSize(edge.width, GRID_BUTTON_HEIGHT)
    buttons[i]:SetPoint("TOPLEFT", grid, "TOPLEFT", edge.left,
      -(GRID_PRIMARY_HEIGHT + M.gap + line * (GRID_BUTTON_HEIGHT + M.gap)))
    buttons[i]:SetShown(extras)
  end

  -- Captions are measured against the column they landed in. A caption that
  -- does not fit is truncated and its full text goes to the button's tooltip;
  -- it is never clipped, and word wrap is never left on inside a 26px button.
  for i = 1, #buttons do
    local button = buttons[i]
    T.FitText(button:GetFontString(), button:GetWidth() - M.gap, button.caption, button)
  end
end

-- What the footer is tall enough for right now. The footer holds the two
-- mutually exclusive action areas, so a view change or the category-buttons
-- option changes exactly this one number and everything anchored above it
-- follows. Only the done view swaps the footer. The all view lists finished
-- mail but is not a place to sweep it: "delete all done" would act on mails
-- the segment does not distinguish, so the all view keeps the category grid --
-- which is exactly as useful there as on the collect view, since a category
-- run works on the inbox and not on the listing.
local function FooterHeight(panel)
  if panel.viewMode == VIEW_DONE then return GRID_BUTTON_HEIGHT end
  if not ShowCategoryButtons() then return GRID_PRIMARY_HEIGHT end
  return GRID_PRIMARY_HEIGHT + Th().Metrics.gap * 2 + GRID_BUTTON_HEIGHT * 2
end

-- Frozen: Core/MailboxUI.lua calls this when the category-buttons option
-- changes. The window's floor is sized for the full grid either way (see
-- CT.MinPanelHeight), so switching the buttons off never moves the window;
-- the two rows they stood on go to the list.
function CT.RefreshCategoryButtons(panel)
  if not panel or not panel.Footer then return end
  panel.Footer:SetHeight(FooterHeight(panel))
  LayoutGrid(panel)
end

local function BuildGrid(panel)
  local T = Th()
  local labels = Labels()

  panel.Grid = CreateFrame("Frame", nil, panel.Footer)
  panel.Grid:SetAllPoints()

  panel._gridButtons = {}
  panel._gridColumns = {}

  for i = 1, #CATEGORY_ORDER do
    local category = CATEGORY_ORDER[i]
    local button = T.CreateButton(nil, panel.Grid)
    button.caption = labels[category] or category
    button:SetText(button.caption)
    button:SetScript("OnClick", function() StartCategoryRun(panel, category) end)
    button:SetScript("OnEnter", function(self)
      if not self.__pbOverflowText then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:ClearLines()
      Th().AddOverflowLine(self, GameTooltip)
      GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    panel._gridButtons[i] = button
  end
end

-------------------------------------------------------------
-- View mode
-------------------------------------------------------------

function SetViewMode(panel, id)
  if panel.viewMode == id then return end
  panel.viewMode = id
  local doneView = (id == VIEW_DONE)
  -- A selection was made over one view's rows; the next view lists others.
  ClearSelection(panel)

  -- See FooterHeight for why only the done view swaps the footer.
  panel.Footer:SetHeight(FooterHeight(panel))
  panel.Grid:SetShown(not doneView)
  panel.DeleteAllDone:SetShown(doneView)

  panel.MailListScroll:SetVerticalScroll(0)
  PaintViewToggle(panel)
  CT.RefreshMailList(panel)
end

-------------------------------------------------------------
-- Build
-------------------------------------------------------------

local function LayoutPanel(panel)
  LayoutViewToggle(panel)
  LayoutGrid(panel)
  if panel.Detail then LayoutDetail(panel.Detail) end
end

function CT.Build(parent)
  local T = ns.Theme
  local M = T.Metrics

  local panel = CreateFrame("Frame", nil, parent)
  panel:SetAllPoints()
  panel.viewMode = VIEW_COLLECT
  panel._filtered = {}
  -- Parallel to _filtered: the list walk's verdict for each listed mail, so the
  -- row binder can dress a row from the mail rather than from the view.
  panel._filteredDone = {}
  panel._rows = {}
  panel._rowParts = {}
  -- The compact row's inline subset of the meta line. A second reused table
  -- rather than a second pass: both are filled by the one walk in BindRow.
  panel._rowBrief = {}

  -- Top row: the view switch, the search box at the far right, and the hint
  -- between them.
  BuildViewToggle(panel)
  BuildSearchBox(panel)

  -- Blank until something needs saying: this line's only remaining job is
  -- the truncated-inbox notice (see UpdateHint).
  panel.Hint = T.CreateText(panel, "secondary")
  panel.Hint:SetPoint("LEFT", panel.ViewToggle, "RIGHT", M.gap, 0)
  panel.Hint:SetPoint("RIGHT", panel.SearchWrap, "LEFT", -M.gap, 0)
  panel.Hint:SetJustifyH("RIGHT")
  panel.Hint:SetWordWrap(false)
  panel.Hint:SetText("")

  -- Bottom: one footer holding the two mutually exclusive action areas. Its
  -- height is the only thing a view change moves.
  panel.Footer = CreateFrame("Frame", nil, panel)
  panel.Footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", M.inset, M.inset)
  panel.Footer:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -M.inset, M.inset)
  panel.Footer:SetHeight(FooterHeight(panel))

  BuildGrid(panel)

  panel.DeleteAllDone = T.CreateButton(nil, panel.Footer)
  panel.DeleteAllDone:SetPoint("TOPLEFT", panel.Footer, "TOPLEFT", 0, 0)
  panel.DeleteAllDone:SetPoint("TOPRIGHT", panel.Footer, "TOPRIGHT", 0, 0)
  panel.DeleteAllDone:SetHeight(GRID_BUTTON_HEIGHT)
  panel.DeleteAllDone:SetText(L()["BTN_DELETE_ALL_DONE"])
  panel.DeleteAllDone:SetScript("OnClick", function() DeleteAllDone(panel) end)
  panel.DeleteAllDone:Hide()

  -- The totals banner: a divider, not a panel, aligned to the same inset as the
  -- grid below it so the columns line up. Its fill is `bandFill`, which is held
  -- at the plate opacity floor -- it carries the run's gold earned/spent
  -- figures, and a text-bearing surface may not depend on the window's own fill
  -- to stay legible.
  panel.Banner = CreateFrame("Frame", nil, panel, "BackdropTemplate")
  panel.Banner:SetPoint("LEFT", panel, "LEFT", M.inset, 0)
  panel.Banner:SetPoint("RIGHT", panel, "RIGHT", -M.inset, 0)
  panel.Banner:SetPoint("BOTTOM", panel.Footer, "TOP", 0, M.gap)
  panel.Banner:SetHeight(M.controlHeight)
  T.ApplyBand(panel.Banner)

  local bannerIcon = panel.Banner:CreateTexture(nil, "ARTWORK")
  bannerIcon:SetSize(M.iconSize, M.iconSize)
  bannerIcon:SetPoint("LEFT", panel.Banner, "LEFT", M.inset, 0)
  bannerIcon:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")

  panel.BannerText = T.CreateText(panel.Banner, "value")
  panel.BannerText:SetPoint("LEFT", bannerIcon, "RIGHT", M.gap, 0)
  panel.BannerText:SetPoint("RIGHT", panel.Banner, "RIGHT", -M.inset, 0)
  panel.BannerText:SetJustifyH("LEFT")

  -- The list absorbs everything between the top row and the banner.
  panel.MailListArea = CreateFrame("Frame", nil, panel, "BackdropTemplate")
  panel.MailListArea:SetPoint("TOPLEFT", panel.ViewToggle, "BOTTOMLEFT", 0, -M.gap)
  panel.MailListArea:SetPoint("RIGHT", panel, "RIGHT", -M.inset, 0)
  panel.MailListArea:SetPoint("BOTTOM", panel.Banner, "TOP", 0, M.gap)
  T.ApplyList(panel.MailListArea)

  -- One gutter width, wide enough that the classic scroll bar -- which anchors
  -- outside its frame's right edge -- clears the container's border art.
  local scroll = CreateFrame("ScrollFrame", nil, panel.MailListArea, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", panel.MailListArea, "TOPLEFT", M.tightGap, -M.tightGap)
  scroll:SetPoint("BOTTOMRIGHT", panel.MailListArea, "BOTTOMRIGHT", -M.scrollGutter, M.tightGap)
  PinScrollBar(scroll, panel.MailListArea)
  panel.MailListScroll = scroll

  panel.MailListChild = CreateFrame("Frame", nil, scroll)
  -- The scroll frame has no measured width until the first layout pass; the
  -- child must not start wider than it, or the list scrolls sideways.
  local childWidth = scroll:GetWidth() or 0
  if childWidth <= 10 then childWidth = FALLBACK_PANEL_WIDTH - M.scrollGutter end
  panel.MailListChild:SetSize(childWidth, 1)
  scroll:SetScrollChild(panel.MailListChild)

  -- HookScript, not SetScript: the template installs its own handlers here and
  -- replacing them desynchronises the scroll bar.
  scroll:HookScript("OnSizeChanged", function(_, width)
    if width and width > 10 then panel.MailListChild:SetWidth(width) end
    UpdateVisibleRows(panel)
  end)
  scroll:HookScript("OnVerticalScroll", function() UpdateVisibleRows(panel) end)

  panel.Empty = T.CreateText(panel.MailListArea, "secondary")
  panel.Empty:SetPoint("TOPLEFT", panel.MailListArea, "TOPLEFT", M.inset * 2, -M.inset * 2)
  panel.Empty:SetPoint("RIGHT", panel.MailListArea, "RIGHT", -M.inset * 2, 0)
  panel.Empty:SetJustifyH("LEFT")
  panel.Empty:Hide()

  BuildDetail(panel)

  -- Synchronous, at the end of build: the grid used to be positioned only by a
  -- size-change hook plus a next-frame callback, so six buttons visibly jumped
  -- into place after the window appeared. Genuine resizes still arrive through
  -- OnSizeChanged.
  LayoutPanel(panel)
  PaintViewToggle(panel)

  panel:SetScript("OnSizeChanged", function(self) LayoutPanel(self) end)
  panel:SetScript("OnShow", function(self)
    LayoutPanel(self)
    CT.RefreshMailList(self)
  end)
  panel:SetScript("OnHide", function(self) HideDetail(self) end)

  return panel
end
