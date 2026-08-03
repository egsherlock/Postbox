local _, ns = ...

-- Postbox :: the window shell.
--
-- One movable, resizable window that replaces the native mailbox: a title bar
-- with a close button, an options cog and a status line; a two-tab bar; and a
-- content area holding one tab panel at a time. This file owns the window, the
-- tabs, the status line, where the window sits on screen, and the mailbox
-- session lifecycle. It owns no mail logic: it asks the domain and the two tab
-- modules to do the work and renders what they report.
--
-- Three things here are subtle enough to be worth reading before editing:
--
--   * Everything that touches MailFrame is taint-sensitive. COMBAT_TAINT.md is
--     the authority; the guards below are load-bearing and each one has a
--     comment saying which failure it prevents.
--   * The status line has three competing writers (see section 4). It is a
--     priority stack, not a text field, because the previous build let an
--     unrelated inbox event erase "Incomplete: 3 left" -- the one message a
--     player most needs to read.
--   * Grid docking is a three-state interaction (docked / dragged this session /
--     free-floating) and users notice when it breaks.

ns.MailboxUI = ns.MailboxUI or {}
local UI = ns.MailboxUI

local max, min, ceil, floor = math.max, math.min, math.ceil, math.floor

-- Underscore-prefixed but public in practice: Core/Skin_EllesmereUI.lua and
-- Core/Skin_ElvUI.lua read `_frame` and `_state.activeTab`, and
-- Core/OptionsPanel.lua writes `_state.freeMoved`. The accessors further down
-- are the preferred route for new code; the fields stay.
UI._state = UI._state or {
  ready          = false,     -- Initialize has run
  visible        = false,     -- our window is up
  mailboxOpen    = false,     -- a mail session is live
  inboxSeen      = false,     -- a real MAIL_INBOX_UPDATE has landed this visit
  activeTab      = "collect",
  freeMoved      = false,     -- the user dragged the window this session (grid mode)
  attachRows     = 1,         -- rows of attachment slots the compose screen shows
  extraH         = 0,         -- transient height added for a second attachment row
  bodyH          = 0,         -- transient height added for a message that outgrew its box
  layoutDeferred = false,     -- a grid reservation is waiting for combat to end
}

-------------------------------------------------------------
-- 0. Lazily resolved dependencies
--
-- Every cross-module reference is resolved at call time, never at file scope,
-- so a TOC reorder degrades to a no-op instead of erroring at load. Every entry
-- point below also survives a nil frame: one error inside an event handler can
-- leave the window half-built with no way back short of /reload.
-------------------------------------------------------------

local function WindowHelpers()
  return ns.Core and ns.Core.UI and ns.Core.UI.Helpers or nil
end

local function L(key)
  local strings = ns.L
  local text = strings and strings[key]
  return type(text) == "string" and text or key
end

-- Format-string reads are protected: a mistyped placeholder in one of the five
-- locale blocks would otherwise raise inside an event handler.
local function LF(key, ...)
  local template = L(key)
  local ok, formatted = pcall(string.format, template, ...)
  return ok and formatted or template
end

local function InCombat()
  return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

local function CollectPanel()
  local frame = UI._frame
  return frame and frame.Tabs and frame.Tabs.collect or nil
end

local function SendPanel()
  local frame = UI._frame
  return frame and frame.Tabs and frame.Tabs.send or nil
end

-- Rebuild the mail list now. Only the open path wants this: the list has to be
-- populated in the same frame the window appears in, or the player sees an empty
-- mailbox blink past.
local function RefreshCollectPanel()
  local panel, collect = CollectPanel(), ns.CollectTab
  if panel and collect and collect.RefreshMailList then
    collect.RefreshMailList(panel)
  end
end

-- Rebuild the mail list on the next frame, once, however many times this is
-- asked for in between. Everything driven by an event uses this rather than the
-- synchronous call above: MAIL_INBOX_UPDATE arrives in bursts -- the initial
-- inbox load, every body fetch, every CheckInbox -- so a single user-visible
-- change used to cost several complete list rebuilds inside a handful of frames.
-- The collect screen owns the dirty flag; it also drops the work entirely while
-- its panel is hidden.
local function QueueCollectRefresh()
  local panel, collect = CollectPanel(), ns.CollectTab
  if not panel or not collect then return end
  if collect.RequestRefresh then
    collect.RequestRefresh(panel)
  elseif collect.RefreshMailList then
    collect.RefreshMailList(panel)
  end
end

-------------------------------------------------------------
-- 1. Options
--
-- Five booleans on the profile. Reads go through the store's non-creating
-- accessor: merely asking whether a flag is set must not write a node into
-- saved variables. Defaults live here rather than being seeded on first read,
-- so an unset option and an option explicitly set to its default behave
-- identically and neither one costs a write.
-------------------------------------------------------------

local OPTION_DEFAULTS = {
  gridDock        = true,
  showTabCounts   = true,
  -- The collect screen's single-line mail rows. Off: the standard row is what
  -- the screen is designed around, and density is a preference, not a default.
  compactRows     = false,
  -- Swaps the two gestures on a to-collect row: on, a plain click OPENS the mail
  -- and shift/right-click collects it. Off, because the screen is a collect
  -- screen -- the common action is the one-click one -- and because a player who
  -- has used it for a while has the other mapping in their hands.
  previewOnClick  = false,
  -- The minimap icon's left-click snapshot (Core/MailMemory.lua). On: the
  -- feature is capture-light and idle when unused, and a feature nobody can
  -- find switched off does not exist.
  mailMemory      = true,
}
-- Right-click-to-attach has no option on purpose (removed in 1.24 after one
-- release as a toggle): with a mail window open, sending the clicked item is
-- what the click means, it is how Blizzard's own Send tab has always
-- behaved, and outside a mail session bags are untouched. An off-switch
-- would only exist to make the addon do less than the default UI.

local OPTION_PATH = {}
for key in pairs(OPTION_DEFAULTS) do
  OPTION_PATH[key] = "profile." .. key
end

function UI.GetOption(key)
  local path = OPTION_PATH[key]
  if not path then return false end

  local store = ns.Store
  local stored = store and store.Get and store.Get(path)
  if stored == nil then return OPTION_DEFAULTS[key] == true end
  return stored == true
end

function UI.SetOption(key, value)
  if not OPTION_PATH[key] then return end
  local store = ns.Store
  local profile = store and store.EnsurePath and store.EnsurePath("profile")
  -- Every profile value is coerced to a boolean here, which is why the
  -- recipient tables live at the saved-variables root instead (see Postbox.lua).
  if profile then profile[key] = value == true end
end

-- The window style for a session with NO host-UI skin: which first-party
-- look Postbox paints itself. A string with its own accessors, like the tab
-- caption below. Read once, at PLAYER_LOGIN, by Core/Skin_Modern.lua's
-- claim -- which is why a change needs a /reload and why these accessors
-- never repaint anything themselves.
--   blizzard  the built-in warm-stone Blizzard-native look (default)
--   modern    the first-party flat skin (Core/Skin_Modern.lua)
-- Under EllesmereUI or ElvUI this setting is inert: those skins outrank it.
local STYLE_CHOICES = { blizzard = true, modern = true }

function UI.GetStyleChoice()
  local store = ns.Store
  local stored = store and store.Get and store.Get("profile.style")
  if STYLE_CHOICES[stored] then return stored end
  return "blizzard"
end

function UI.SetStyleChoice(style)
  if not STYLE_CHOICES[style] then return end
  local store = ns.Store
  local profile = store and store.EnsurePath and store.EnsurePath("profile")
  if profile then profile.style = style end
end

-- The Mail tab's caption mode -- how the inbox shows through the tab while
-- the mailbox is open. A string, so it gets its own accessors rather than a
-- widened SetOption: the boolean coercion above is a guarantee, not an
-- accident. `showTabCounts` stays the segments' own switch; this one owns
-- the tab.
--   counts  "Mail (2/5)" -- still to collect over total
--   total   "Mail (5)"   -- just how much is sitting there
--   dot     "Mail •"     -- an accent dot while anything is uncollected
--   none    "Mail"       -- the default
local TAB_CAPTION_MODES = { counts = true, total = true, dot = true, none = true }

function UI.GetTabCaptionMode()
  local store = ns.Store
  local stored = store and store.Get and store.Get("profile.tabCaption")
  if TAB_CAPTION_MODES[stored] then return stored end
  -- Default OFF: a caption on the primary tab is visible UI, so wearing one
  -- is the user's call -- same reasoning as the minimap icon's default.
  return "none"
end

function UI.SetTabCaptionMode(mode)
  if not TAB_CAPTION_MODES[mode] then return end
  local store = ns.Store
  local profile = store and store.EnsurePath and store.EnsurePath("profile")
  if profile then profile.tabCaption = mode end
  UI.RefreshCollectTabCounts()
end

-------------------------------------------------------------
-- 2. The native mail frame
--
-- Postbox replaces the native mailbox rather than decorating it, so MailFrame
-- stays loaded (the send-mail plumbing needs it) but invisible.
--
-- The one remaining write below taints MailFrame for the session; that is
-- structural and documented in COMBAT_TAINT.md 4. What matters here is that no
-- write happens from a path where it would be *blocked*, and that the frame is
-- never made visible at a moment when we are not allowed to hide it again.
-------------------------------------------------------------

local function HideNativeMailFrame()
  if MailFrame and type(MailFrame.SetAlpha) == "function" then
    MailFrame:SetAlpha(0)
  end
end

-- Enum.PlayerInteractionType.MailInfo. The numeric value is the fallback for a
-- client that does not publish the enum; section 9 matches incoming interaction
-- events against the same constant.
local MAIL_INTERACTION = 17

local function MailInteractionType()
  local enum = type(Enum) == "table" and Enum.PlayerInteractionType or nil
  local kind = enum and enum.MailInfo
  if type(kind) == "number" then return kind end
  return MAIL_INTERACTION
end

-- Ends the mail session -- in combat and out of it -- without ever writing to
-- MailFrame. COMBAT_TAINT.md 7 fix #3.
--
-- CloseMail() ends the interaction. The interaction manager then runs Blizzard's
-- own MailFrame_Hide, which reaches exactly the HideUIPanel(MailFrame) this
-- function used to call -- but from secure execution, so the panel is released
-- from the layout without the frame being tainted. Calling HideUIPanel ourselves
-- bought nothing even out of combat: MailFrame's own OnHide handler calls
-- CloseMail(), so the old path looped straight back into this one, having
-- tainted the frame on the way past. The emote, the close sound, the bags and
-- the send-mail edit boxes are all cleared by that same Blizzard handler, so
-- none of it is lost.
local function CloseMailbox()
  if type(CloseMail) == "function" then
    CloseMail()
    return
  end

  -- The same end, one layer down, if a client ever stops exporting the global.
  local manager = C_PlayerInteractionManager
  if type(manager) == "table" and type(manager.ClearInteraction) == "function" then
    manager.ClearInteraction(MailInteractionType())
    return
  end

  -- Unreachable on any client that can open a mailbox at all, and kept only so
  -- that "close" still means close if both of the above ever vanish. This is the
  -- one branch that touches the protected frame; nothing above it may.
  if MailFrame and type(HideUIPanel) == "function" then
    HideUIPanel(MailFrame)
  end
end

-------------------------------------------------------------
-- 3. Status line
--
-- Three different things compete for one label, and they are not
-- interchangeable:
--
--   activity  transient, while a collection run is in progress ("Remaining: 4")
--   outcome   sticky, what a finished run actually did ("Incomplete: 3 left")
--   summary   what is WRONG while nothing is running, and nothing otherwise
--
-- Priority is activity > outcome > summary, and an outcome is cleared only by
-- the next run, by the mailbox closing, or by an explicit clear. That is the
-- whole fix for the defect this replaced: the inbox-update handler recomputed
-- the idle summary and wrote it straight over the label, so a run that stopped
-- with mail still in the mailbox announced it for a fraction of a second and
-- was then overwritten by an unrelated event. An outcome the player needs to
-- read now outlives every event that did not produce it.
--
-- The summary layer used to state "N to collect / M total", under an option.
-- The collect screen's segments now carry Collect / Done / All with those exact
-- numbers on them, so the line was restating what was already on screen a
-- centimetre below it -- and an option existed only to turn the restatement off.
-- What is left is the one thing the segments cannot say: that some of that mail
-- will not come out. A healthy idle mailbox therefore has a BLANK status line,
-- and that blank is the message.
--
-- The collect screen reports run state through the three setters below; it must
-- not reach into `frame.Status` itself. If something does anyway, the write is
-- adopted as an outcome rather than being silently clobbered on the next
-- render -- see AdoptForeignText.
-------------------------------------------------------------

local STATUS_DEFAULT_TONE = "textSecondary"

local status = {
  activity = nil, activityTone = nil,
  outcome  = nil, outcomeTone  = nil,
  summary  = nil,
  rendered = "",              -- what we last put on the label
}

local function StatusLabel()
  local frame = UI._frame
  return frame and frame.Status or nil
end

-- The label no longer holds what we last rendered, so somebody wrote it
-- directly. Take that text over as an outcome instead of erasing it on the next
-- render: an unexplained blank status is worse than a status we did not author.
-- A live activity is authoritative, so a foreign write during a run is only
-- re-synced, not adopted.
local function AdoptForeignText()
  local label = StatusLabel()
  if not label or type(label.GetText) ~= "function" then return end

  local shown = label:GetText() or ""
  if shown == status.rendered then return end

  status.rendered = shown
  if status.activity then return end

  status.outcome = (shown ~= "" and shown) or nil
  status.outcomeTone = nil
end

local function RenderStatus()
  local label = StatusLabel()
  if not label then return end

  local text, tone
  if status.activity then
    text, tone = status.activity, status.activityTone
  elseif status.outcome then
    text, tone = status.outcome, status.outcomeTone
  else
    text, tone = status.summary or "", nil
  end

  label:SetText(text)
  status.rendered = text

  local theme = ns.Theme
  if theme and theme.SetColor then
    theme.SetColor(label, tone or STATUS_DEFAULT_TONE)
  end
end

-- What a run is doing right now. `tone` is an optional palette token. Passing
-- nil ends the activity without asserting an outcome.
function UI.SetStatusActivity(text, tone)
  AdoptForeignText()
  if type(text) == "string" and text ~= "" then
    status.activity, status.activityTone = text, tone
    -- A new run supersedes the previous run's verdict.
    status.outcome, status.outcomeTone = nil, nil
  else
    status.activity, status.activityTone = nil, nil
  end
  RenderStatus()
end

-- What a run ended up doing. Sticky: nothing but another run, an explicit
-- clear, or the mailbox closing takes it off the label.
function UI.SetStatusOutcome(text, tone)
  AdoptForeignText()
  -- An outcome is a report on the activity it replaces, so the activity ends.
  status.activity, status.activityTone = nil, nil
  if type(text) == "string" and text ~= "" then
    status.outcome, status.outcomeTone = text, tone
  else
    status.outcome, status.outcomeTone = nil, nil
  end
  RenderStatus()
end

function UI.ClearStatus()
  status.activity, status.activityTone = nil, nil
  status.outcome, status.outcomeTone = nil, nil
  RenderStatus()
end

-- Recomputes the idle line and repaints. Safe to call from anywhere at any time:
-- it only ever touches the lowest-priority layer, so it cannot overwrite a run's
-- activity or its outcome.
--
-- Says one thing, unconditionally, and only when it is true: some mail in this
-- inbox will not come out. A mail the server refused this visit still counts as
-- to-collect on the segment above, and trying again will not empty it until
-- whatever the game objected to is dealt with -- which is precisely the fact a
-- count cannot carry. Everything healthy renders as nothing at all.
--
-- No extra event traffic: this rides the same MAIL_INBOX_UPDATE the counts
-- already follow, and the domain answers 0 without touching the inbox whenever
-- nothing has been refused.
function UI.UpdateStatusSummary()
  AdoptForeignText()

  status.summary = nil
  local mail = ns.MailService
  local stuck = (mail and type(mail.StuckCount) == "function" and mail.StuckCount()) or 0
  if stuck > 0 then
    -- An inline escape rather than a tone: RenderStatus paints the whole label
    -- one colour from the layer that won, and this layer has no tone of its own
    -- to pass. Colouring the text itself keeps the warning with the warning.
    local text = LF("STATUS_STUCK", stuck)
    local theme = ns.Theme
    if theme and theme.Colorize then text = theme.Colorize("warning", text) end
    status.summary = text
  end

  -- The saved record renders NOTHING of its own. Its stuck fingerprints were
  -- seeded into the live registry at mail open, so anything that still
  -- matters is already the "Stuck: N" line above, with its triangles and its
  -- tooltip -- one presentation for one situation, whether the run was this
  -- session or last. A separate "Last visit: N could not be taken" sentence
  -- fired precisely when the seeded fingerprints matched nothing, which
  -- almost always means the problem resolved itself -- stale numbers shown
  -- at the one moment they stopped being true. The record's remaining jobs
  -- are the revival payload and the /postbox debug report; housekeeping
  -- below erases it once the inbox is VERIFIABLY empty.
  if not status.summary then
    local collect = ns.CollectTab
    local record = collect and type(collect.GetLastRunRecord) == "function"
      and collect.GetLastRunRecord()
    if record then
      local numItems = (type(GetInboxNumItems) == "function" and GetInboxNumItems()) or 0
      -- "Empty" is only believable after a real MAIL_INBOX_UPDATE this
      -- visit: the client's inbox cache reads 0 between MAIL_SHOW and the
      -- first update (documented at MailService's registry and CollectTab's
      -- run start), and erasing on that cold read would delete the record
      -- before its fingerprints had a chance to revive anything.
      if numItems == 0 and UI._state.inboxSeen
        and type(collect.ClearLastRunRecord) == "function" then
        collect.ClearLastRunRecord()
      end
    end
  end

  RenderStatus()
end

-- Is a collection run under way? Two independent sources, because either one
-- alone has a blind spot: the activity layer knows what the collect screen has
-- told us, and the domain's channel owner knows about a command sequence the
-- screen never announced (a single mail clicked in the list, say).
local function RunInProgress()
  if status.activity then return true end
  local mail = ns.MailService
  if mail and type(mail.IsBusy) == "function" then
    return mail.IsBusy() and true or false
  end
  return false
end

-------------------------------------------------------------
-- 4. Position, docking and size
--
-- Grid docking (option `gridDock`, default on) reuses the invisible MailFrame
-- as a correctly-sized spacer in the client's UI-panel layout: overriding its
-- panel width to match Postbox makes other Blizzard windows reserve room for
-- the size Postbox actually is, and Postbox then rides in that slot.
--
-- Three states, and they are easy to collapse into two by accident:
--   docked        grid docking on, window sitting in the slot
--   dragged       grid docking on, user has moved it -- honour the new position
--                 for this session only, return to the slot on the next open
--   free-floating grid docking off -- no width override, hold the position
--
-- The two halves have very different taint properties. Reserving the space
-- writes MailFrame's protected attributes and is blocked in combat, so it is
-- deferred and re-applied on PLAYER_REGEN_ENABLED. Anchoring our own window
-- against MailFrame only reads it and is always safe. Keep them apart.
--
-- SIZE. The minimum height is DERIVED, never chosen: it is the shell's own
-- chrome plus whatever the tab panels say they need right now. BOTH screens
-- answer, and the floor is the taller answer:
--
--   compose  the fixed bands plus a message body at its own floor, and it moves
--            with the attachment rows (Core/SendTab.lua section 1 states the
--            invariant and owns the sum)
--   collect  the fixed furniture plus a list tall enough for five compact mail
--            rows or three standard ones -- one number covering both layouts, so
--            the compact-rows option never moves the window (Core/CollectTab.lua,
--            CT.MinPanelHeight)
--
-- The window therefore cannot be dragged -- or restored from saved variables --
-- small enough to crush the message box or reduce the mail list to a peephole,
-- which is what a hardcoded 480x400 floor allowed. The minimum also SHIPS AS THE
-- DEFAULT: the window opens at its floor, so that floor has to be comfortable.
-------------------------------------------------------------

-- The height of the window template's title-bar art. A platform constant.
local TITLE_BAR_HEIGHT = 24

-- Width has no derived floor -- nothing on either tab has a horizontal minimum
-- beyond the category bar's tiles, and those measure themselves -- so it stays a
-- chosen number, and the default width is that minimum. There is deliberately no
-- minimum or default HEIGHT here: both are computed below.
local MIN_WIDTH, DEFAULT_WIDTH = 480, 480
-- The ceilings are taste, not structure: past this the window is bigger than the
-- content it holds.
local MAX_WIDTH, MAX_HEIGHT = 750, 600

-- Only reached if a tab module is missing entirely, in which case there is no
-- screen to protect. Every real floor comes from the panels themselves.
local FALLBACK_PANEL_HEIGHT = 300

-- TRANSIENT HEIGHT, and the reason there is a word for it.
--
-- Two things layer height on top of the size the user actually chose, and
-- NEITHER is ever persisted:
--
--   extraH  a second row of attachment slots appeared (SetAttachmentRows)
--   bodyH   the message being typed outgrew its box (SetMessageExtraHeight)
--
-- The BASE height -- what the resize grip sets, what saved variables hold, what
-- the window reopens at -- is therefore always the window's height less this
-- sum. Every reader of "the user's height" goes through here, and the
-- persistence layer subtracts exactly this before it writes, so no combination
-- of a tall message and a second attachment row can ever be saved as a size the
-- user never chose.
local function TotalExtra()
  return UI._state.extraH + UI._state.bodyH
end

-- How much taller the window may get before its bottom edge leaves the screen.
-- Negative when it is already over the edge, which is what lets the elastic
-- extension give height BACK rather than only take it.
--
-- The window and UIParent are measured in their own effective scales, so the
-- screen's bottom is converted into the window's before the subtraction: a host
-- UI that scales either one would otherwise have us clamping against a number
-- in the wrong units.
local SCREEN_EDGE_PAD = 4

local function GrowthRoom(frame)
  local top = frame:GetTop()
  if type(top) ~= "number" then return 0 end

  local scale = frame:GetEffectiveScale()
  if type(scale) ~= "number" or scale <= 0 then scale = 1 end
  local parentScale = UIParent:GetEffectiveScale()
  if type(parentScale) ~= "number" or parentScale <= 0 then parentScale = 1 end

  local bottom = ((UIParent:GetBottom() or 0) * parentScale) / scale
  return (top - (bottom + SCREEN_EDGE_PAD)) - (frame:GetHeight() or 0)
end

-- THE VERTICAL CHAIN, top to bottom. One function answers it, so the two places
-- that care -- the height floor and the anchors themselves -- cannot disagree,
-- and so the whole of it can be read in one place:
--
--   frame top
--     TITLE_BAR_HEIGHT   24, the template's title-bar art
--     titleGap           = inset, the same margin the window gives up on every
--                         other side. Previously this was zero: the bar was
--                         anchored straight to the bottom of the title art, so
--                         two 28px tabs sat hard against the window's own
--                         caption with nothing between them, which is what made
--                         them look crushed rather than placed. (The bar's
--                         HORIZONTAL margin is wider -- see ContentInset.)
--   tab bar              = tabHeight (28)
--     tabGap             = snug (6), deliberately one step BELOW the general
--                         sibling gap and below titleGap. A tab and the panel
--                         it opens are one thing; the asymmetry is what says
--                         so. Grouping by proximity only works if the gaps
--                         actually differ.
--   content
--     inset              the bottom margin, as on the other three sides
--
-- The fallbacks are the live metrics, not older ones: a missing theme must
-- degrade to the same layout rather than to a subtly different one.
--
-- Returns inset, titleGap, tabHeight, tabGap.
local function ChromeChain()
  local metrics = (ns.Theme and ns.Theme.Metrics) or {}
  local space   = metrics.space or {}
  local inset   = tonumber(metrics.inset) or 10
  return inset,
         inset,
         tonumber(metrics.tabHeight) or 28,
         tonumber(space.snug) or 6
end

-- THE HORIZONTAL INSET OF THE CONTENT COLUMN, measured from the window's edge.
--
-- Two margins, not one, and that is the whole point: the shell gives up `inset`
-- to frame.Content, and each tab panel then gives up its own Theme.Metrics.inset
-- to its first control -- the collect screen's Mail/Read segments, the compose
-- screen's recipient caption. So everything a player actually reads starts one
-- inset further in than the window edge suggests.
--
-- The tab bar is anchored here rather than at the window's own inset, so the two
-- big tab buttons line up with the column they open instead of overhanging it by
-- a margin on each side. Derived from the one token both halves read, so moving
-- the panel margin moves the tabs with it.
local function ContentInset()
  local shellInset = ChromeChain()
  local metrics = (ns.Theme and ns.Theme.Metrics) or {}
  return shellInset + (tonumber(metrics.inset) or shellInset)
end

-- Everything the shell puts above and below a tab panel.
local function ChromeHeight()
  local inset, titleGap, tabHeight, tabGap = ChromeChain()
  return TITLE_BAR_HEIGHT + titleGap + tabHeight + tabGap + inset
end

-- Both tabs share one window, so the floor is the taller of the two demands.
-- A tab module that publishes no minimum simply does not raise it.
--
-- Only ONE of the two moves: the compose screen's answer takes `rows` and grows
-- with the attachment band, while the collect screen's is a constant of the
-- theme's metrics -- it deliberately does not consult the compact-rows option,
-- so toggling that option cannot resize the window. Which of the two wins at one
-- attachment row is close enough to depend on the client's measured font
-- heights, and nothing here needs to know: the max is the answer either way, and
-- a second attachment row puts the compose screen ahead regardless.
local function MinWindowHeight(rows)
  local panel = FALLBACK_PANEL_HEIGHT

  local send = ns.SendTab
  if send and type(send.MinPanelHeight) == "function" then
    -- Parenthesised: a cross-module call that grew a second return value would
    -- otherwise spill it into tonumber's base argument, which throws.
    panel = max(panel, tonumber((send.MinPanelHeight(rows))) or 0)
  end

  local collect = ns.CollectTab
  if collect and type(collect.MinPanelHeight) == "function" then
    panel = max(panel, tonumber((collect.MinPanelHeight())) or 0)
  end

  return ceil(ChromeHeight() + panel)
end

-- The floor with no extra attachment rows: the size the window opens at, the
-- size a saved height is clamped up to, and the bound the persistence layer
-- clamps to when it writes (it subtracts the transient extra height first, so
-- the base floor is the right bound for it).
local function BaseMinHeight()
  return MinWindowHeight(1)
end

-- The ceiling, from the one place that owns it. MAX_HEIGHT is taste, so the
-- derived floor overrides it wherever the two would cross -- a window that
-- cannot be as tall as its own content needs is not a matter of taste.
--
-- Read by the resize grip's bounds AND by the message box's elastic extension:
-- the window must never end up at a height the user could not have dragged it
-- to, or the next grab of the grip would snap it back down to one.
local function MaxWindowHeight()
  return max(MAX_HEIGHT, MinWindowHeight(UI._state.attachRows))
end

-- THE FLOOR FOR ONE DRAG, which is not the same thing as the window's floor.
--
-- MinWindowHeight above is derived from an EMPTY compose screen: it guarantees
-- the bands cannot collide and nothing more. A message already in the box is a
-- second claim on the height, and it is the grip -- and only the grip -- that
-- has to honour it: dragging the window down to its structural floor with ten
-- lines standing put a scroll bar over text the user could read a moment before.
--
-- Deliberately NOT folded into MinWindowHeight, which is also the clamp
-- ApplyResizeBounds applies to the window itself and the bound the persistence
-- layer writes against. A floor that moved with the draft would GROW the window
-- on the next attachment row and would write a height nobody chose; this one
-- only ever stops a drag early, and only while the grip is held.
--
-- The Collect tab has no message box, so its drag floor is the derived one
-- unchanged.
local function DragMinHeight(frame)
  local floorHeight = MinWindowHeight(UI._state.attachRows)
  if UI._state.activeTab ~= "send" then return floorHeight end

  local send = ns.SendTab
  if not (send and type(send.MessageFloorExtra) == "function") then return floorHeight end

  local height = (frame and frame.GetHeight) and tonumber((frame:GetHeight())) or 0
  -- What the drag could take off before it meets the derived floor. At or below
  -- the floor already there is nothing to withhold.
  local room = height - floorHeight
  if room <= 0 then return floorHeight end

  -- Parenthesised: a cross-module call that grew a second return value would
  -- otherwise spill it into tonumber's base argument, which throws.
  local extra = tonumber((send.MessageFloorExtra(room))) or 0
  if extra <= 0 then return floorHeight end

  return floorHeight + extra
end

-- Applies the current floor to the resize grip AND to the window itself.
--
-- The second half is what makes a stored size safe: Lib/UI/Window.lua clamps on
-- SAVE, so a height saved under an older, lower floor would otherwise be
-- restored intact and reopen the window in the broken state. Nothing else in
-- this file is allowed to call SetResizeBounds.
local function ApplyResizeBounds()
  local frame = UI._frame
  if not frame then return end

  local minHeight = MinWindowHeight(UI._state.attachRows)
  local maxHeight = MaxWindowHeight()

  if type(frame.SetResizeBounds) == "function" then
    frame:SetResizeBounds(MIN_WIDTH, minHeight, MAX_WIDTH, maxHeight)
  elseif type(frame.SetMinResize) == "function" then
    frame:SetMinResize(MIN_WIDTH, minHeight)
    if type(frame.SetMaxResize) == "function" then
      frame:SetMaxResize(MAX_WIDTH, maxHeight)
    end
  end

  local width  = tonumber(frame:GetWidth()) or 0
  local height = tonumber(frame:GetHeight()) or 0
  local clampedW = max(MIN_WIDTH, min(MAX_WIDTH, width))
  -- The message box's elastic extension rides on top of BOTH bounds. It is
  -- content the window is showing right now rather than a size anybody chose,
  -- so the clamp must neither claw it back nor let the floor drop through it.
  -- (The attachment rows need no such term: the floor above already grew by
  -- exactly their height, which is why they are absent from this line.)
  local body = UI._state.bodyH
  local clampedH = max(minHeight + body, min(maxHeight + body, height))
  if clampedW ~= width or clampedH ~= height then
    -- Pin first, so the correction grows the window down and right rather than
    -- moving the corner the user placed.
    local helpers = WindowHelpers()
    if helpers and helpers.PinFrameTopLeft then helpers.PinFrameTopLeft(frame) end
    frame:SetSize(clampedW, clampedH)
  end
end

local function ReserveGridWidth(width)
  if not MailFrame then return end

  if InCombat() then
    -- The window still opens and still docks; only the panel-grid reservation
    -- waits for PLAYER_REGEN_ENABLED.
    UI._state.layoutDeferred = true
    return
  end

  -- nil clears the override and reverts MailFrame to its own width.
  if type(SetUIPanelAttribute) == "function" then
    pcall(SetUIPanelAttribute, MailFrame, "width", width)
  end
  if type(UpdateUIPanelPositions) == "function" then
    pcall(UpdateUIPanelPositions, MailFrame)
  end
end

-- Taint-free: this reads MailFrame's position and writes only our own anchor.
local function DockToSlot()
  local frame = UI._frame
  if not frame or not MailFrame then return end
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", MailFrame, "TOPLEFT", 0, 0)
end

local function ShouldDock()
  return UI.GetOption("gridDock") and not UI._state.freeMoved
end

function UI.ApplyWindowLayout()
  local frame = UI._frame
  if not frame then return end

  -- Only while a mail session is live. Every caller is inside one except the
  -- CLOSING path, which reaches this through SetAttachmentRows(1) on its way
  -- out: without the guard, shutting the mailbox writes MailFrame's protected
  -- panel attributes one last time, for a window that is already being hidden
  -- and a slot nothing is about to occupy. COMBAT_TAINT.md.
  --
  -- The options panel's grid-dock toggle is the other caller that can arrive
  -- with no mailbox open, and it loses nothing either: the next open runs the
  -- full layout, which is where a cleared or re-taken reservation lands anyway.
  if not UI._state.mailboxOpen then return end

  if UI.GetOption("gridDock") then
    ReserveGridWidth(frame:GetWidth())
    if not UI._state.freeMoved then
      DockToSlot()
      -- One deferred pass, in addition to the synchronous one above, purely to
      -- absorb the width change once the panel system has finished positioning
      -- MailFrame. Never instead of the synchronous pass.
      if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0, function()
          if ShouldDock() then DockToSlot() end
        end)
      end
    end
  else
    -- Free-floating: drop the size override (MailFrame keeps its own
    -- reservation) and hold the window's current screen position.
    -- NOTE: this is still an insecure SetUIPanelAttribute write on MailFrame,
    -- so switching gridDock off does not shrink the taint surface -- and if
    -- the SetAlpha taint in HideNativeMailFrame is ever removed
    -- (COMBAT_TAINT.md 7, #5/#6), this line must be revisited or it will
    -- quietly keep re-tainting MailFrame on every layout pass.
    ReserveGridWidth(nil)
    local helpers = WindowHelpers()
    if helpers and helpers.PinFrameTopLeft then helpers.PinFrameTopLeft(frame) end
  end
end

-- The compose screen reveals a second row of attachment slots as attachments
-- are added. Its message body is anchored above the attachment area, so without
-- this the body would shrink underneath the user. Instead the window itself
-- gets the row's height, pinned by its top-left so it grows downward only.
--
-- The row raises the FLOOR by the same amount as the height, which is the half
-- that was missing: growing the window alone still left it draggable back down
-- to a floor computed for one row, and the message box paid for the difference.
--
-- The persisted height is the base size the user chose with the resize grip;
-- this extra is layered on top and subtracted again before saving (the
-- foundation layer's persistence takes extraHeightFn for exactly that).
local function AttachmentRowHeight()
  local metrics = ns.Theme and ns.Theme.Metrics
  if not metrics then return 40 end
  -- One slot plus the tight gap that separates two rows of them -- the same two
  -- numbers the compose screen lays its slots out from, so the window grows by
  -- exactly the height that appeared inside it.
  return (tonumber(metrics.slotSize) or 36) + (tonumber(metrics.tightGap) or 4)
end

function UI.SetAttachmentRows(rows)
  local frame = UI._frame
  if not frame then return end

  rows = max(1, floor(tonumber(rows) or 1))
  if rows == UI._state.attachRows then return end

  local extra = (rows - 1) * AttachmentRowHeight()
  local delta = extra - UI._state.extraH
  UI._state.attachRows = rows
  UI._state.extraH = extra

  local helpers = WindowHelpers()
  if helpers and helpers.PinFrameTopLeft then helpers.PinFrameTopLeft(frame) end
  frame:SetHeight(frame:GetHeight() + delta)
  -- Then the floor, which reads the row count set above -- so when a row goes
  -- away the floor has already dropped by the time the clamp inside runs, and
  -- the window keeps the smaller height it was just given.
  ApplyResizeBounds()
  -- The row just moved the window's bottom edge, so an elastic extension
  -- granted a moment ago may now hang off the bottom of the screen. Asking for
  -- the same extension re-runs the clamp and gives back whatever no longer fits.
  if UI._state.bodyH > 0 then UI.SetMessageExtraHeight(UI._state.bodyH) end
  UI.ApplyWindowLayout()
end

-- THE MESSAGE BOX'S ELASTIC EXTENSION.
--
-- The compose screen asks for `pixels` of extra window height so that what is
-- being typed fits without scrolling, and asks again on every reflow: it is a
-- desired total, not an increment. Everything about it is transient. It is
-- layered on the user's base height rather than replacing it, it is subtracted
-- again before every save, it is dropped the moment the compose screen goes
-- away, and it MOVES neither the resize floor nor the ceiling -- it obeys them.
--
-- Growth is DOWNWARD: the window is pinned by its top-left, and in grid mode it
-- is anchored there to the panel slot, so the corner the user placed does not
-- move. Two things stop it: the bottom of the screen, and the same ceiling the
-- resize grip enforces (a window auto-grown past a height the grip allows would
-- be snapped back down the instant the grip was next grabbed, and the saved
-- base would disagree with what was on screen).
--
-- A clamp is not a refusal: the message box scrolls for whatever it did not
-- get, which is the only state in which its scroll bar is on screen at all.
--
-- Returns the extension actually applied, so the caller measures against what
-- it was given rather than against what it asked for.
function UI.SetMessageExtraHeight(pixels)
  local frame = UI._frame
  if not frame then return 0 end

  pixels = max(0, floor(tonumber(pixels) or 0))
  -- Only the compose screen has a message box. Every other state -- the collect
  -- screen, a closing mailbox -- is the base height and nothing else.
  if UI._state.activeTab ~= "send" then pixels = 0 end

  local current = UI._state.bodyH
  -- Both limits are computed for EVERY request rather than only for a growing
  -- one, because either can tighten under a standing extension: the window can
  -- be dragged down the screen, and an attachment row can raise the floor.
  local screenRoom = current + floor(GrowthRoom(frame))
  local ceilingRoom = MaxWindowHeight() - ((frame:GetHeight() or 0) - current)
  local allowed = max(0, min(screenRoom, ceilingRoom))
  if pixels > allowed then pixels = allowed end
  if pixels == current then return current end

  UI._state.bodyH = pixels

  -- Docked, the window's own top-left IS the anchor and re-pinning it to the
  -- screen would take it out of the panel slot; free-floating, the pin is what
  -- makes SetHeight grow downward instead of symmetrically from the centre.
  if not ShouldDock() then
    local helpers = WindowHelpers()
    if helpers and helpers.PinFrameTopLeft then helpers.PinFrameTopLeft(frame) end
  end
  frame:SetHeight(frame:GetHeight() + (pixels - current))

  -- Deliberately no ApplyWindowLayout: the WIDTH has not changed, and that is
  -- the only thing the grid reservation is about. Re-reserving here would write
  -- MailFrame's protected attributes on a keystroke.
  return pixels
end

-- What the message extension is contributing to the window's height right now.
--
-- The compose screen measures its own field against this to recover the room
-- the user's base height gives it, so the two must never hold separate copies:
-- the setter above clamps, the attachment rows re-clamp, and a remembered
-- answer would be wrong from the first clamp onwards.
function UI.GetMessageExtraHeight()
  return UI._state.bodyH
end

-- The resize grip has taken hold. Whatever height the window is showing right
-- now becomes the base: the message extension is folded into it rather than
-- dropped, so nothing moves under the cursor at the instant of the grab and the
-- drag starts from exactly the size the user can see. The compose screen is told
-- to stand down for the duration, and re-reads its own baseline on release --
-- which is what stops the window growing straight back and undoing a drag that
-- made it shorter.
--
-- The attachment rows are NOT adopted: a row is still on screen after the drag
-- and still owns its height.
local function AdoptTransientHeight(frame)
  -- Remembered so a press that never becomes a drag can be undone on release:
  -- adopting on a bare click would otherwise fold the extension into the base
  -- and write it to the saved height (see the release callback in section 4).
  UI._state.adoptedBodyH = UI._state.bodyH
  UI._state.adoptedAtHeight = (frame and frame.GetHeight) and frame:GetHeight() or nil
  UI._state.bodyH = 0
  local send = ns.SendTab
  if send and send.SuspendElastic then send.SuspendElastic(true) end
end

-------------------------------------------------------------
-- 5. Tabs
--
-- Flat plates drawn by the theme, not PanelTabButtonTemplate: that template's
-- art is a Left/Middle/Right assembly only Blizzard's own resize helper
-- stretches, so a bare SetWidth widened the clickable area while the graphic
-- stayed put. See the commentary in Core/Theme.lua. This file owns only their
-- position and width.
-------------------------------------------------------------

local TAB_ORDER = { "collect", "send" }
local TAB_LABEL_KEY = { collect = "TAB_COLLECT", send = "TAB_SEND" }

-- The collect tab's caption carries "(still to collect / total)" while the
-- mailbox is open, so the Send tab shows at a glance that mail is waiting.
-- Same numbers as the segment captions -- CT.InboxCounts, the one walk --
-- and the same option gates both. The suffix is composed in code, parens and
-- all, exactly as the segment captions compose theirs.
--
-- With nothing left to collect the whole suffix drops to the disabled grey:
-- a full-strength "(0/4)" glanced at from the Send tab reads as "you've got
-- mail" when the truthful reading is "four read mails are sitting there".
local function UpdateCollectTabText()
  local frame = UI._frame
  local tab = frame and frame.TabButtons and frame.TabButtons.collect
  if not tab then return end

  local text = L("TAB_COLLECT")
  local mode = UI.GetTabCaptionMode()
  local collect = ns.CollectTab
  if UI._state.mailboxOpen
    and mode ~= "none"
    and collect and type(collect.InboxCounts) == "function" then
    local toCollect, _, total = collect.InboxCounts()
    toCollect, total = tonumber(toCollect) or 0, tonumber(total) or 0

    local theme = ns.Theme
    local suffix
    if mode == "dot" then
      -- The lightest possible "you've got mail": an accent dot, gone the
      -- moment nothing is left to collect. The live accent, not the palette
      -- token -- under a host skin the user's own colour is the accent.
      if toCollect > 0 and theme and theme.GetAccent then
        local r, g, b = theme.GetAccent()
        suffix = ("|cff%02x%02x%02x\226\128\162|r"):format(
          math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
          math.floor(b * 255 + 0.5))
      end
    elseif total > 0 then
      suffix = mode == "total" and ("(" .. total .. ")")
        or ("(" .. toCollect .. "/" .. total .. ")")
      if toCollect == 0 and theme and theme.Colorize then
        suffix = theme.Colorize("textDisabled", suffix)
      end
    end
    if suffix then text = text .. " " .. suffix end
  end

  -- Never a bare SetText: the skins hide or recolour this label, and SetText
  -- alone undoes that (see Theme.SetTabText).
  local theme = ns.Theme
  if theme and theme.SetTabText then
    theme.SetTabText(tab, text)
  else
    tab:SetText(text)
  end
end

-- MAIL_INBOX_UPDATE arrives in bursts, and with the collect panel hidden (the
-- one case this caption is FOR) nothing else has walked the inbox -- so a
-- synchronous update per event would pay one walk per event. Coalesced to the
-- next frame instead, same pattern as the collect list's own refresh.
local tabCountQueued = false
local function QueueCollectTabText()
  if tabCountQueued then return end
  tabCountQueued = true
  local ok = pcall(C_Timer.After, 0, function()
    tabCountQueued = false
    UpdateCollectTabText()
  end)
  if not ok then
    tabCountQueued = false
    UpdateCollectTabText()
  end
end

function UI.SelectTab(tabId)
  if not TAB_LABEL_KEY[tabId] then return end

  UI._state.activeTab = tabId

  local frame = UI._frame
  if frame then
    local theme = ns.Theme
    for i = 1, #TAB_ORDER do
      local id = TAB_ORDER[i]
      local button, panel = frame.TabButtons[id], frame.Tabs[id]
      -- Selection goes through the theme, which hands over entirely to a
      -- skin-installed override when there is one. Painting here as well means
      -- the two fight on every switch.
      if button and theme and theme.SetTabSelected then
        theme.SetTabSelected(button, id == tabId)
      end
      if panel then panel:SetShown(id == tabId) end
    end
  end

  local send = ns.SendTab
  if tabId == "send" then
    -- Right-click-to-attach from the bags depends solely on this flag. It is a
    -- plain non-frame API; showing SendMailFrame is what used to taint, and is
    -- not needed for any of it (COMBAT_TAINT.md 4).
    if send and send.ActivateNativeSendMail then send.ActivateNativeSendMail() end
  else
    -- The attach flag stays armed on the collect tab too -- re-armed here
    -- AFTER the panel loop, because hiding the compose panel above ran its
    -- OnHide, which dropped it. The overlays stay compose-only; section 5b
    -- is what answers the attach this arming allows.
    if send and send.ArmNativeSendMail then send.ArmNativeSendMail() end
    if send and send.ClearBagOverlays then send.ClearBagOverlays() end
    -- The window's compose-only extra height belongs to the compose screen --
    -- both kinds of it. Dropping them here rather than trusting the screen to
    -- remember means the window can never be left tall on the collect tab,
    -- which has neither an attachment row nor a message box to justify it.
    -- (activeTab is already the new tab, so the message extension would refuse
    -- to grow again from here anyway; this is what gives back the standing one.)
    UI.SetMessageExtraHeight(0)
    UI.SetAttachmentRows(1)
  end
end

-------------------------------------------------------------
-- 5b. Quick attach
--
-- With the client's right-click-to-attach armed on the collect tab (SelectTab
-- above), a bag click attaches to the hidden draft exactly as it does on the
-- compose tab -- the client does the attaching, we never touch the container
-- buttons. The client then announces it with MAIL_SEND_INFO_UPDATE, and when
-- that reports MORE attachments than the last look while the compose tab is
-- not on screen, the player just aimed an item at the draft from the collect
-- tab, and the window follows them to it. Growth only: removals, refreshes
-- and the send itself all fire the same event, and none of them is a reason
-- to change tabs. Nothing in this path touches a protected frame or API, so
-- it works in combat like the rest of the window.
-------------------------------------------------------------

local lastAttachmentCount = 0

local function ReadAttachmentCount()
  local send = ns.SendTab
  if send and type(send.GetAttachmentCount) == "function" then
    return send.GetAttachmentCount()
  end
  return 0
end

-- The watcher measures growth, so its baseline is re-read at the session
-- boundary (OnMailShow) rather than trusted across one.
local function SyncQuickAttachBaseline()
  lastAttachmentCount = ReadAttachmentCount()
end

local function OnSendAttachmentsChanged()
  local count = ReadAttachmentCount()
  local grew = count > lastAttachmentCount
  lastAttachmentCount = count

  if not grew or not UI._state.mailboxOpen then return end
  if UI._state.activeTab == "send" then return end
  UI.SelectTab("send")
end

-- Frozen: Core/OptionsPanel.lua calls this when the tab-count option changes.
function UI.RefreshCollectTabCounts()
  local panel, collect = CollectPanel(), ns.CollectTab
  if panel and collect and collect.UpdateTabCounts then
    collect.UpdateTabCounts(panel)
  end
  UpdateCollectTabText()
end

-- Frozen: Core/OptionsPanel.lua calls this when the compact-row option changes.
-- Synchronous, not queued: this one answers a click the player just made on a
-- list they are looking at, and the collect screen's own entry point is what
-- preserves their place in it across the change of row height.
function UI.RefreshCollectRowLayout()
  local panel, collect = CollectPanel(), ns.CollectTab
  if panel and collect and collect.ApplyRowLayout then
    collect.ApplyRowLayout(panel)
  end
end

-------------------------------------------------------------
-- 6. Construction
--
-- The main window must keep using a Blizzard window template that supplies
-- TitleText, CloseButton, Inset and NineSlice: both skins re-point or strip
-- those by name, and the options panel and the recipient manager use the same
-- template, which is what makes the three windows match. Compatibility
-- constraint, not a design preference.
-------------------------------------------------------------

local WINDOW_TEMPLATE = "BasicFrameTemplateWithInset"

local function OpenOptions(owner)
  -- Postbox's own window, never a Blizzard context menu: menu frames are
  -- Compositor-guarded (CreateTexture is disallowed on them) and the only route
  -- to their submenu panels taints Blizzard's menu pipeline. See COMBAT_TAINT.md.
  local panel = ns.OptionsPanel
  if panel and panel.Toggle then panel.Toggle(owner) end
end

local function BuildOptionsButton(frame, theme)
  local button = CreateFrame("Button", nil, frame)
  button:SetSize(18, 18)
  -- Two different title bars, two different centres: the host skins rebuild
  -- the bar and -4 sits level with their title text, while the stock
  -- template's TitleText rides higher and -4 read a couple of pixels low
  -- beside it. ns.Skin is claimed at PLAYER_LOGIN, before any mailbox can
  -- build this frame.
  button:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, ns.Skin and -4 or -2)
  button:SetFrameLevel(frame:GetFrameLevel() + 20)

  button.icon = button:CreateTexture(nil, "ARTWORK")
  button.icon:SetAllPoints()
  button.icon:SetTexture("Interface\\Buttons\\UI-OptionsButton")
  -- The live accent, resolved through the theme so a host UI's own accent wins.
  -- Never cached: EllesmereUI re-tints this exact texture through
  -- Skin.RefreshAccents when the user changes their colour.
  if theme and theme.GetAccent then
    button.icon:SetVertexColor(theme.GetAccent())
  end

  -- Highlight the gear shape itself rather than a square box around a round icon.
  button:SetHighlightTexture("Interface\\Buttons\\UI-OptionsButton")
  local highlight = button:GetHighlightTexture()
  if highlight then highlight:SetBlendMode("ADD") end

  button:SetScript("OnClick", function(self) OpenOptions(self) end)
  button:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L("OPTIONS_TITLE"))
    GameTooltip:AddLine(L("OPTIONS_COG_TOOLTIP"), 1, 1, 1, true)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function()
    if GameTooltip then GameTooltip:Hide() end
  end)

  return button
end

local function BuildFrame()
  if UI._frame then return end

  local theme = ns.Theme
  local helpers = WindowHelpers()
  local metrics = (theme and theme.Metrics) or {}
  -- The vertical chain, from the one function that owns it (section 4).
  local inset, titleGap, tabHeight, tabGap = ChromeChain()
  -- `gap` is now horizontal only: the space BETWEEN the two tabs. The vertical
  -- gaps have their own names above, because they mean different things.
  local gap = tonumber(metrics.gap) or 8

  local store = ns.Store
  local windowStore = (store and store.EnsurePath and store.EnsurePath("profile.window", {})) or {}

  local frame = CreateFrame("Frame", "PostboxFrame", UIParent, WINDOW_TEMPLATE)
  -- The default size IS the derived minimum: the window opens at its floor.
  -- Nothing here is free to choose a height.
  frame:SetSize(DEFAULT_WIDTH, BaseMinHeight())
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 50)
  frame:SetFrameStrata("DIALOG")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:SetResizable(true)
  frame:SetScript("OnMouseDown", function(self) self:Raise() end)
  frame:Hide()

  -- The resize bounds are applied once the panels exist, at the foot of this
  -- function, because they are derived from what those panels need.

  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self)
    self:StartMoving()
    -- In grid mode a drag is a per-session override: honour the new spot until
    -- the mailbox is reopened, then return to the slot.
    UI._state.freeMoved = true
  end)
  -- The foundation layer's persistence replaces this handler and chains to it,
  -- so the window still stops moving if that layer is ever unavailable.
  frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

  if theme and theme.ApplyFrameTheme then theme.ApplyFrameTheme(frame) end
  if helpers and helpers.RegisterEscClose then helpers.RegisterEscClose(frame) end

  -- Escape closes Postbox through UISpecialFrames, which only hides our overlay
  -- -- the mailbox interaction would otherwise stay open invisibly (and in
  -- combat stay stuck until combat ends). So a hide while the mailbox is still
  -- open closes the mailbox too, exactly as the close button does.
  --
  -- Crucially the close is DEFERRED by a frame. Escape runs through Blizzard's
  -- secure CloseSpecialWindows, which calls our insecure OnHide inline; closing
  -- the mailbox synchronously from there taints that secure keypath and breaks
  -- the NEXT in-combat mailbox open. A zero-second timer decouples it from the
  -- keypress. OnMailClosed clears mailboxOpen before it hides the frame, so a
  -- normal close never schedules a redundant one.
  frame:HookScript("OnHide", function()
    UI._state.visible = false
    if not UI._state.mailboxOpen then return end
    if C_Timer and type(C_Timer.After) == "function" then
      C_Timer.After(0, function()
        if UI._state.mailboxOpen then CloseMailbox() end
      end)
    else
      CloseMailbox()
    end
  end)

  -- Title.
  if frame.TitleText then
    frame.TitleText:SetText(L("FRAME_TITLE"))
    frame.TitleText:ClearAllPoints()
    if frame.TitleBg then
      frame.TitleText:SetPoint("CENTER", frame.TitleBg, "CENTER", 0, 0)
    else
      frame.TitleText:SetPoint("TOP", frame, "TOP", 0, -11)
    end
  end

  -- The close button ends the mail session rather than just hiding the overlay.
  if frame.CloseButton then
    frame.CloseButton:SetScript("OnClick", function() CloseMailbox() end)
  end

  -- Status line: top-right of the title bar, left of the close button. Secondary
  -- metadata, so it takes the secondary text role -- never the disabled font,
  -- which would render the most informative line on screen as inactive. No
  -- width is set: an unconstrained font string cannot clip a long translation.
  if theme and theme.CreateText then
    frame.Status = theme.CreateText(frame, "secondary", "OVERLAY")
  end
  if frame.Status then
    frame.Status:SetJustifyH("RIGHT")
    frame.Status:SetWordWrap(false)
    if frame.CloseButton then
      frame.Status:SetPoint("RIGHT", frame.CloseButton, "LEFT", -8, 0)
    else
      frame.Status:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -10)
    end
    -- Bounded on the left as well: an unconstrained string cannot clip, but
    -- it CAN run leftward under the centred window title -- which the
    -- last-visit summary, the longest line this label ever carries, did.
    -- Bounded, it end-truncates with an ellipsis instead.
    if frame.TitleText then
      frame.Status:SetPoint("LEFT", frame.TitleText, "RIGHT", 10, 0)
    else
      frame.Status:SetPoint("LEFT", frame, "CENTER", 30, 0)
    end
    frame.Status:SetText("")

    -- The truncated tail is the most informative part (the game's own refusal
    -- text), so a hover region over the label offers the full line. Inert
    -- whenever the text fits.
    local statusHover = CreateFrame("Frame", nil, frame)
    statusHover:SetAllPoints(frame.Status)
    -- Motion only: clicks pass through, so the title bar drags and the close
    -- button clicks exactly as before.
    statusHover:EnableMouse(true)
    statusHover:SetMouseClickEnabled(false)
    statusHover:SetMouseMotionEnabled(true)
    statusHover:SetScript("OnEnter", function(self)
      local label = frame.Status
      local text = label and label:GetText() or ""
      if text == "" then return end

      -- Two things worth a tooltip: a truncated line (the full text), and a
      -- stuck count (WHICH mails, in the same words the row tooltips use).
      -- The details come from the registry's validated read, so this list and
      -- the row triangles can never disagree.
      local mail = ns.MailService
      local details = mail and type(mail.StuckDetails) == "function"
        and mail.StuckDetails() or nil
      local truncated = label.IsTruncated and label:IsTruncated()
      if not details and not truncated then return end

      GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
      GameTooltip:SetText(text, 1, 1, 1, 1, true)
      if details then
        for i = 1, #details do
          local d = details[i]
          local line = d.subject
          if line == "" then line = d.sender
          elseif d.sender ~= "" then line = d.sender .. " - " .. d.subject end
          GameTooltip:AddLine(line, 1, 1, 1, true)
          if d.reason then
            GameTooltip:AddLine(LF("STUCK_LINE", d.reason), 0.75, 0.75, 0.75, true)
          end
        end
      end
      GameTooltip:Show()
    end)
    statusHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end

  frame.OptionsButton = BuildOptionsButton(frame, theme)

  -- Resize grip. The foundation layer debounces the size write, so a drag does
  -- not write saved variables sixty times a second; the stop callback only runs
  -- on release. The start callback is what makes the GRIP WIN over the message
  -- box's elastic extension: see AdoptTransientHeight.
  if helpers and helpers.CreateResizeButton then
    frame.ResizeButton = helpers.CreateResizeButton(frame, function(resized)
      -- A press that never moved is not a resize. Give the adopted extension
      -- back BEFORE anything saves -- otherwise a mis-click on the grip while a
      -- long message stands writes base+extension to disk as the chosen height
      -- -- and tell the compose screen its baseline is unchanged, so the
      -- release does not convert the standing extension into slack either.
      local st = UI._state
      local h = (resized and resized.GetHeight) and resized:GetHeight() or nil
      local bareClick = st.adoptedAtHeight ~= nil and h ~= nil
        and h - st.adoptedAtHeight < 0.5 and st.adoptedAtHeight - h < 0.5
      if bareClick then st.bodyH = st.adoptedBodyH or 0 end
      st.adoptedBodyH, st.adoptedAtHeight = nil, nil
      if helpers.SaveFramePosition then helpers.SaveFramePosition(resized, windowStore) end
      UI.ApplyWindowLayout()
      -- Last, and after the re-dock: the compose screen re-reads its baseline
      -- from the size the user settled on, at the position it settled at.
      local send = ns.SendTab
      if send and send.SuspendElastic then send.SuspendElastic(false, bareClick) end
    end, AdoptTransientHeight, DragMinHeight)
  end

  -- Tab bar. One inset below the title bar, and the CONTENT inset on the left
  -- and right: the tabs share their edges with the screen they open (section 4,
  -- ContentInset) rather than running the full width of the window, which left
  -- them visibly wider than everything underneath them.
  local tabBarTop = TITLE_BAR_HEIGHT + titleGap
  local tabInset = ContentInset()
  frame.TabBar = CreateFrame("Frame", nil, frame)
  frame.TabBar:SetPoint("TOPLEFT", frame, "TOPLEFT", tabInset, -tabBarTop)
  frame.TabBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -tabInset, -tabBarTop)
  frame.TabBar:SetHeight(tabHeight)
  frame.TabBar:SetFrameLevel(frame:GetFrameLevel() + 9)
  if theme and theme.ApplyTabBarBg then theme.ApplyTabBarBg(frame.TabBar) end

  -- Content area: one tab panel at a time, filling everything below the bar.
  frame.Content = CreateFrame("Frame", nil, frame)
  frame.Content:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -(tabBarTop + tabHeight + tabGap))
  frame.Content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)

  frame.TabButtons = {}
  frame.Tabs = {}

  for i = 1, #TAB_ORDER do
    local id = TAB_ORDER[i]
    local tab = theme and theme.CreateTab and theme.CreateTab("PostboxFrameTab" .. i, frame.TabBar)
    if tab then
      tab:SetText(L(TAB_LABEL_KEY[id]))
      tab:SetFrameLevel(frame:GetFrameLevel() + 10)
      -- Both skins match tabs by `tabId` and maintain `isSelected`; the theme
      -- gives every tab an `__activeBg` texture they can hide.
      tab.tabId = id
      if theme.StyleTab then theme.StyleTab(tab) end
      tab:SetScript("OnClick", function() UI.SelectTab(id) end)
      frame.TabButtons[id] = tab
    end
  end

  -- The tabs divide the bar evenly at every window width. Edges are derived
  -- from the usable width rather than one width rounded and repeated: rounding
  -- discards up to a pixel per tab, so the last one stops short of the bar's
  -- edge and the row visibly drifts off-centre as the window is resized.
  local columns = {}
  local function LayoutTabs()
    local bar = frame.TabBar
    if not bar then return end

    local width = bar:GetWidth() or 0
    if width < 10 then
      -- The bar is anchored to the window's edges, so its measured width reads
      -- zero until the first layout pass. The window's own width is explicitly
      -- set, so derive from that and the very first paint is already correct --
      -- nothing may be positioned only by a deferred callback.
      width = (frame:GetWidth() or 0) - tabInset * 2
    end
    if width < 10 then return end

    local edges = theme and theme.ColumnEdges
        and theme.ColumnEdges(width, #TAB_ORDER, gap, columns)
    if not edges then return end

    for i = 1, #TAB_ORDER do
      local tab, column = frame.TabButtons[TAB_ORDER[i]], edges[i]
      if tab and column then
        tab:ClearAllPoints()
        tab:SetWidth(max(1, column.width))
        tab:SetPoint("TOPLEFT", bar, "TOPLEFT", column.left, 0)
      end
    end
  end

  frame.TabBar:SetScript("OnSizeChanged", LayoutTabs)
  frame:HookScript("OnShow", function()
    LayoutTabs()
    -- In addition to the synchronous pass, never instead of it: this one exists
    -- only to absorb a width change from the grid dock settling.
    if C_Timer and type(C_Timer.After) == "function" then C_Timer.After(0, LayoutTabs) end
  end)
  LayoutTabs()

  -- Published before the screens are built: a screen may reach the shell (for
  -- the status line, or to grow the window) from its own construction, and by
  -- this point every field it can legitimately want exists.
  UI._frame = frame

  local collect, send = ns.CollectTab, ns.SendTab
  frame.Tabs.collect = collect and collect.Build and collect.Build(frame.Content) or nil
  frame.Tabs.send    = send and send.Build and send.Build(frame.Content) or nil

  -- A SAVED size predates the current floor -- it was written by an older build,
  -- or under a locale whose fonts were shorter -- so it is clamped before it is
  -- restored as well as when it is written. Clamping only on save is what would
  -- let a user with a small stored size reopen straight back into the broken
  -- layout; ApplyResizeBounds below is the second line of the same defence, for
  -- a size that reaches the frame by any other route.
  local baseMin = BaseMinHeight()
  if type(windowStore.width) == "number" then
    windowStore.width = max(MIN_WIDTH, min(MAX_WIDTH, windowStore.width))
  end
  if type(windowStore.height) == "number" then
    windowStore.height = max(baseMin, min(max(MAX_HEIGHT, baseMin), windowStore.height))
  end

  if helpers and helpers.ApplyWindowPersistence then
    helpers.ApplyWindowPersistence(frame, windowStore, {
      minW = MIN_WIDTH, maxW = MAX_WIDTH,
      -- The base floor, not the current one: the persistence layer subtracts
      -- ALL of the compose screen's transient height -- the attachment row and
      -- the message extension both -- before it clamps and writes.
      minH = baseMin, maxH = max(MAX_HEIGHT, baseMin),
      extraHeightFn = TotalExtra,
    })
  end

  -- After the panels and after the restore: the floor is derived from the former
  -- and has to be able to correct the latter.
  ApplyResizeBounds()

  UI.SelectTab(UI._state.activeTab)

  -- Optional host-UI skin; a no-op unless EllesmereUI or ElvUI is installed.
  -- When both are, EllesmereUI has claimed ns.Skin by now (it registers at
  -- PLAYER_LOGIN, and this window is built no earlier than the first mailbox).
  -- The refresh hook is installed unconditionally and guarded inside, so a skin
  -- that arrives after the window was built still gets its passes.
  if ns.Skin and ns.Skin.Apply then ns.Skin.Apply(frame) end
  frame:HookScript("OnShow", function(self)
    if ns.Skin and ns.Skin.Refresh then ns.Skin.Refresh(self) end
  end)
end

-------------------------------------------------------------
-- 7. Mailbox session lifecycle
-------------------------------------------------------------

local function ResetDraft()
  local panel, send = SendPanel(), ns.SendTab
  if panel and send and send.Reset then send.Reset(panel) end
end

-- A mailbox opened. Three different triggers report it -- MAIL_SHOW, the
-- interaction manager's show event for the mail interaction, and the native
-- frame being shown -- and they fire in different orders, and more than one of
-- them fires on a single open. They all converge here, and the full open path
-- runs once per session: a second trigger only re-asserts the two things a
-- second trigger can legitimately change.
local function OnMailShow()
  HideNativeMailFrame()

  if UI._state.mailboxOpen then
    -- Re-dock only. This is the taint-free half of the layout; re-running the
    -- grid reservation would write MailFrame's protected attributes two or
    -- three times for one open, to no effect.
    if ShouldDock() then DockToSlot() end
    return
  end

  UI._state.mailboxOpen = true
  -- The inbox always reads empty between MAIL_SHOW and the first
  -- MAIL_INBOX_UPDATE; anything that would treat "empty" as a fact about the
  -- mailbox must wait until this flips (see UpdateStatusSummary's erasure).
  UI._state.inboxSeen = false
  SyncQuickAttachBaseline()
  BuildFrame()

  UI.ClearStatus()
  ResetDraft()
  -- Re-assert the active tab on every open so the native send-mail state is
  -- re-armed; BuildFrame only selects a tab on the very first open.
  UI.SelectTab(UI._state.activeTab)
  UI.Show(true)
  -- Before the list refresh: the revived registry is what paints the row
  -- triangles on the very first build after a relog.
  local collectTab = ns.CollectTab
  if collectTab and type(collectTab.SeedStuckFromRecord) == "function" then
    collectTab.SeedStuckFromRecord()
  end
  RefreshCollectPanel()
  UI.UpdateStatusSummary()
  -- After the refresh, which records the inbox counts this reads.
  UpdateCollectTabText()
  -- Dock last, now that both our window and the invisible MailFrame are shown
  -- and positioned.
  UI.ApplyWindowLayout()
end

-- The mail session ended. MAIL_CLOSED and the interaction manager's hide event
-- both fire for one close, so this is idempotent.
local function OnMailClosed()
  if not UI._state.mailboxOpen and not UI._state.visible then return end

  -- Cleared before the frame is hidden: the OnHide hook reads this to decide
  -- whether Escape orphaned an open mailbox, and a normal close must not
  -- schedule a redundant one.
  UI._state.mailboxOpen = false
  UI._state.inboxSeen = false
  -- The per-session drag override ends with the session, so the window returns
  -- to its grid slot next time.
  UI._state.freeMoved = false

  -- The stuck registry deliberately SURVIVES this boundary (see
  -- .dev/SPEC-RunMemory.md). It was once cleared here, on the argument that a
  -- stale "your bags are full" is worse than no marker; in practice the
  -- opposite bit harder -- reopen the mailbox and every warning was gone, so
  -- the one mail that would not come out looked exactly like the ones that
  -- would. The marker is a reminder that an attempt failed, phrased in the
  -- game's own words; a retry re-establishes the truth in one click, and a
  -- collected mail already drops its entry via ForgetStuck. Entries die with
  -- the session -- nothing is saved.

  -- Mail arrives while the player is away from the
  -- mailbox, so the counts from this visit describe an inbox that no longer
  -- exists. The next read walks rather than trusting them.
  local collect = ns.CollectTab
  if collect and collect.InvalidateCounts then collect.InvalidateCounts() end

  -- The session boundary for run memory's saved half: whatever the registry
  -- holds now is what a relog must be able to revive, however the refusals
  -- got there -- a finished run, an abandoned one, or a single take.
  if collect and type(collect.SyncStuckRecord) == "function" then
    collect.SyncStuckRecord()
  end

  -- mailboxOpen is already false, so this strips the count suffix -- the
  -- numbers describe an inbox the player has walked away from.
  UpdateCollectTabText()

  local send = ns.SendTab
  if send then
    if send.ClearBagOverlays then send.ClearBagOverlays() end
    if send.DeactivateNativeSendMail then send.DeactivateNativeSendMail() end
    ResetDraft()
  end

  -- Give back the compose screen's transient extra height -- the attachment row
  -- and the message extension both -- before anything persists a size, so the
  -- window reopens at the size the user chose. The compose screen drops them on
  -- reset too; doing it here as well means the window can never carry either
  -- into the next session if that ever stops.
  UI.SetMessageExtraHeight(0)
  UI.SetAttachmentRows(1)

  -- Any layout waiting on combat is moot once the mailbox is shut -- including
  -- one the line above may just have queued.
  UI._state.layoutDeferred = false

  if UI._frame then UI._frame:Hide() end
  UI._state.visible = false
  UI.ClearStatus()

  -- MailFrame is deliberately not touched here. Blizzard's own secure hide runs
  -- from the interaction manager and puts the frame away for us, so restoring
  -- its alpha and hiding it were two more writes to a protected frame in aid of
  -- a "tidy default state" nothing reads -- and making it visible in order to
  -- hide it again is precisely the sequence that is not guaranteed to be allowed
  -- a moment later. It stays at alpha 0, which is what the next open wants
  -- anyway, and a /reload restores it. COMBAT_TAINT.md 7 fix #3.
end

-------------------------------------------------------------
-- 8. Public API
-------------------------------------------------------------

function UI.Show(shouldShow)
  -- The window is only ever up while a mailbox is open; it is not a standalone
  -- screen and there is nothing useful in it away from a mailbox.
  local show = shouldShow == true and UI._state.mailboxOpen
  UI._state.visible = show and true or false

  local frame = UI._frame
  if not frame then return end

  if show then
    HideNativeMailFrame()
    frame:SetAlpha(1)
    frame:Show()
  else
    -- Deliberately does not restore MailFrame: hiding our window while the
    -- session is live routes through the OnHide hook, which ends the session,
    -- and OnMailClosed owns the native frame's visibility.
    frame:Hide()
  end
end

function UI.IsMailboxOpen()
  return UI._state.mailboxOpen == true
end

-- There is deliberately no Toggle/IsVisible/GetActiveTab here. All three were
-- uncalled: the window is not a standalone screen anything toggles -- it lives
-- and dies with the mail session -- and the two skins read `_state.activeTab`
-- directly, which is the documented, frozen contract. An accessor nothing calls
-- is a second definition of the same state to keep true.

-------------------------------------------------------------
-- 9. Event plumbing
-------------------------------------------------------------

-- MAIL_INTERACTION is declared in section 2, where the close path uses it too.
local function IsMailInteraction(kind)
  if kind == MAIL_INTERACTION then return true end
  local enum = type(Enum) == "table" and Enum.PlayerInteractionType or nil
  return enum ~= nil and kind == enum.MailInfo
end

function UI.Initialize()
  if UI._state.ready then return end
  UI._state.ready = true

  local bus = ns.Events
  if not bus then return end

  -- There is deliberately no MailFrame:HookScript("OnShow", ...) here. It was a
  -- third route into OnMailShow, and it was both redundant and expensive:
  -- installing a script handler on a protected frame from insecure code is
  -- itself a write to that frame, so it tainted MailFrame at login, before a
  -- mailbox had even been opened. The one path that shows MailFrame is the
  -- interaction manager's ShowFrame -> MailFrame_Show, which is driven by the
  -- interaction event registered below, and MAIL_SHOW fires for the same
  -- session -- so both an initial open and every repeat open are already
  -- covered twice over, and OnMailShow is idempotent by design.
  -- COMBAT_TAINT.md 4.
  bus.Register("MAIL_SHOW", function()
    HideNativeMailFrame()
    OnMailShow()
  end)

  bus.Register("MAIL_CLOSED", function()
    OnMailClosed()
  end)

  -- Quick attach (section 5b). Registered on the bus rather than on the
  -- compose panel: the whole point is noticing an attachment land while that
  -- panel is hidden, which is exactly when its own registration is off.
  bus.Register("MAIL_SEND_INFO_UPDATE", OnSendAttachmentsChanged)

  bus.Register("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, kind)
    if not IsMailInteraction(kind) then return end
    HideNativeMailFrame()
    OnMailShow()
  end)

  bus.Register("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, kind)
    if IsMailInteraction(kind) then OnMailClosed() end
  end)

  bus.Register("MAIL_INBOX_UPDATE", function()
    -- The inbox moved, so what the collect screen last counted is no longer
    -- true. Said before either line below reads it: the refresh recounts and
    -- records as it rebuilds, but it is coalesced to the next frame AND skipped
    -- entirely while its panel is hidden -- so the summary, which is rendered
    -- now and shows on every tab, would otherwise be reporting the last visit's
    -- numbers.
    local collect = ns.CollectTab
    if collect and collect.InvalidateCounts then collect.InvalidateCounts() end

    -- Only a live visit's updates count as having seen the inbox: a stray
    -- MAIL_INBOX_UPDATE away from the mailbox reads a cleared cache and must
    -- not license the last-run record's erasure.
    if UI._state.mailboxOpen then UI._state.inboxSeen = true end

    -- A run refreshes the list itself as it goes; refreshing again from here
    -- would be a second pass per mail over the same data.
    if UI._state.visible and not RunInProgress() then
      QueueCollectRefresh()
    end
    -- Safe unconditionally: this only recomputes the idle summary, which is the
    -- lowest-priority layer and can never displace a run's status.
    UI.UpdateStatusSummary()
    -- The tab caption's numbers moved with the inbox. Queued, not synchronous:
    -- with the collect panel hidden this is the only reader, and a walk per
    -- burst event would be paid for one visible change.
    QueueCollectTabText()
  end)

  bus.Register("MAIL_SUCCESS", function()
    -- Until the domain publishes a run observable the collect screen still
    -- wants this nudge, so the list follows each collected mail rather than
    -- waiting for the next inbox update.
    local collect = ns.CollectTab
    if collect and collect.OnMailSuccess then collect.OnMailSuccess() end
  end)

  bus.Register("PLAYER_REGEN_ENABLED", function()
    -- Combat ended: apply the grid reservation that had to be deferred because
    -- it writes MailFrame's protected panel attributes.
    if not UI._state.layoutDeferred then return end
    UI._state.layoutDeferred = false
    if UI._state.mailboxOpen and UI._frame then UI.ApplyWindowLayout() end
  end)
end
