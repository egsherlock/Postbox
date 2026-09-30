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
  extraW         = 0,         -- transient width lent while the Mail tab's top row needs more
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

-- Format-string reads are protected: a mistyped placeholder in one of the seven
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
-- The switches on the profile, below; the settings that are a word or a
-- number (style, quality mark, read mail, History's days, the row and grid
-- arrangements...) have accessor pairs of their own after them. Reads go
-- through the store's non-creating accessor: merely asking whether a flag is
-- set must not write a node into saved variables. Defaults live here rather
-- than being seeded on first read, so an unset option and an option
-- explicitly set to its default behave identically and neither one costs a
-- write.
-------------------------------------------------------------

local OPTION_DEFAULTS = {
  gridDock        = true,
  showTabCounts   = true,
  -- The collect screen's single-line mail rows. On: with the figures packed
  -- to the right edge a one-line row carries everything a list is scanned
  -- for, and half again as many mails fit. The two-line row is one click away.
  compactRows     = true,
  -- (How a one-line row's figures stand, in columns or packed, is a word,
  -- not a switch: UI.GetRowPacking below. It was the lineUpColumns switch.)
  -- Swaps the two gestures on a to-collect row: on, a plain click OPENS the mail
  -- and shift/right-click collects it. Off, because the screen is a collect
  -- screen -- the common action is the one-click one -- and because a player who
  -- has used it for a while has the other mapping in their hands.
  previewOnClick  = false,
  -- Mail Memory (Core/MailMemory.lua): every character's last-seen mailbox,
  -- in its own window and in this one. On: the feature is capture-light and
  -- idle when unused, and a feature nobody can find switched off does not
  -- exist.
  mailMemory      = true,
  -- One chat line at login when another character's mail is close to being
  -- lost (Core/MailMemory, section 2b). On: that is the mail people lose.
  mailWarnings    = true,
  -- The read mail folded away under its divider, by a click on it, and kept
  -- so between visits (Core/CollectTab.lua, RV.Folded). Off: it is simply
  -- the rest of the list, and the scroll bar is the whole list.
  readFolded      = false,
  -- Right-click-to-attach while the MAIL tab is showing (section 5b). Off,
  -- and this is the one default that was argued the other way first: it
  -- shipped as always-on in 1.24 on the grounds that with a mail window open,
  -- sending the clicked item is what the click means. In use it is not -- a
  -- mailbox visit is where auction wins get equipped and gear gets enchanted,
  -- and a right-click that silently becomes "send this" instead is a surprise
  -- to a player who has never heard of the feature. The Send tab attaches on
  -- right-click either way: that is the client's own behaviour and this
  -- setting neither adds nor removes it.
  attachFromMail  = false,
  -- The collect screen's one-click sweeps (bought, sold, canceled, expired,
  -- other, from alts, and each character group's) under the full-width
  -- Collect button. On: they are what the screen has always offered. Off is
  -- for the player who only ever takes everything, and would rather have
  -- their rows back for the list.
  showCategoryButtons = true,
  -- The totals band under the Mail tab's list: earned and spent across the
  -- mail listed. On: it is what the tab has always shown. Off, the blocks
  -- under the list close up and the window's floor comes down with them
  -- (CollectTab, CT.MinPanelHeight). The arrange mode hides and shows it too.
  showTotals      = true,
  -- (keepRecipient, "leave the recipient in the To: box after a send", is
  -- now one of three answers: UI.GetAfterSendKeep, which reads it once to
  -- carry an old profile over.)
  -- The stack count on a mail row's item icon, and the edge of a second card
  -- behind it when the mail holds more than one item (CollectTab,
  -- RV.PaintCount), in the Mail tab, History and Mail Memory. On: it is how
  -- bags and the game's own inbox show a stack, and it lets an auction
  -- mail's subject drop the count the icon already writes.
  iconCounts      = true,
}
-- What a mail row shows, and in what order, is no longer three switches here
-- (rowGold, rowSlots, rowExpiry): it is the row's arrangement, UI.GetRowLayout
-- below, which reads those three switches only to carry an old profile over.

local OPTION_PATH = {}
for key in pairs(OPTION_DEFAULTS) do
  OPTION_PATH[key] = "profile." .. key
end

-- The settings a list refresh reads for every row -- these switches, and the
-- row arrangement, gold, time left and quality mark below, and the category
-- grid's arrangement -- answered from memory until one of them is written. Every write to them is one of this
-- section's setters or one of the resets below, and each of those calls
-- ForgetSettings; a saved-variables root or profile table other than the one
-- the answers were read from (the client restoring saved variables, anything
-- swapping the profile) forgets them as well. A new writer of any of these
-- keys, anywhere, has to go through a setter or call ForgetSettings too.
-- The gold's and the time left's answers are one per arrangement, kept
-- under each one's key (UI.GetGoldMode, UI.GetExpiryWhen).
local settingsMemo = { opt = {}, gold = {}, expiry = {} }

local function ForgetSettings()
  local memo = settingsMemo
  local opt = memo.opt
  for key in pairs(opt) do opt[key] = nil end
  local gold, expiry = memo.gold, memo.expiry
  for key in pairs(gold) do gold[key] = nil end
  for key in pairs(expiry) do expiry[key] = nil end
  memo.root, memo.profile = nil, nil
  memo.qIcon, memo.qName = nil, nil
  memo.layout, memo.slots = nil, nil
  memo.packing = nil
  memo.history, memo.age, memo.large = nil, nil, nil
  memo.grid, memo.gridText = nil, nil
end

-- The root is read off the global the store is bound to (Postbox.lua), not
-- through Store.Get: this runs for every setting a row asks for, and a call
-- per read was most of what the memo is here to save. Absent, it is nil, and
-- the first read through the store that creates it is a new root like any
-- other.
local function Settings()
  local memo = settingsMemo
  local root = PostboxDB
  local profile = type(root) == "table" and root.profile or nil
  if memo.root ~= root or memo.profile ~= profile then
    ForgetSettings()
    memo.root, memo.profile = root, profile
  end
  return memo
end

function UI.GetOption(key)
  local path = OPTION_PATH[key]
  if not path then return false end

  local memo = Settings()
  local known = memo.opt[key]
  if known ~= nil then return known end

  local store = ns.Store
  local stored = store and store.Get and store.Get(path)
  local value
  if stored == nil then
    value = OPTION_DEFAULTS[key] == true
  else
    value = stored == true
  end
  memo.opt[key] = value
  return value
end

function UI.SetOption(key, value)
  if not OPTION_PATH[key] then return end
  local store = ns.Store
  local profile = store and store.EnsurePath and store.EnsurePath("profile")
  -- Every profile value is coerced to a boolean here, which is why the
  -- recipient tables live at the saved-variables root instead (see Postbox.lua).
  if profile then profile[key] = value == true end
  ForgetSettings()
end

-- RESET TO DEFAULTS (the options panel's footer).
--
-- Everything under `profile` is a setting except the keys named in
-- RESET_KEEP, which are the player's own data and survive. Clearing rather
-- than listing is the point: a setting added next month is reset by this
-- without anyone having to remember it exists, because every accessor reads
-- a missing value as its default. Player-made data belongs at the
-- saved-variables root (Postbox.lua, SCHEMA), where this never looks; data
-- that has to live under `profile` goes in RESET_KEEP or the first reset
-- deletes it.
--
-- A table is emptied where it stands, never replaced. The store memoises
-- every path it has resolved (Lib/Store.lua) and the windows hold their
-- position tables for the whole session (Lib/UI/Window.lua), so a fresh
-- table would leave the minimap icon reading, and both windows saving, into
-- a table nothing saves. The price is that an EMPTY table has to read as the
-- default too -- which the window, recipient-window and minimap tables all
-- do -- and so must any table-valued setting added after them.
local RESET_KEEP = {
  recipientHistory = true,  -- the Send tab's recent recipients (ContactService)
}

-- One step of the re-apply below. Every step runs whatever the one before it
-- did: the settings are already cleared, and a screen left half on the old
-- settings because an unrelated repaint threw is worse than the error. The
-- error is still reported, through the handler every other error reaches.
local function ResetStep(fn, ...)
  if type(fn) ~= "function" then return end
  local ok, err = pcall(fn, ...)
  if not ok and type(geterrorhandler) == "function" then
    local handler = geterrorhandler()
    if type(handler) == "function" then handler(err) end
  end
end

-- `profile` cleared as described above: a table emptied where it stands,
-- anything else removed. `keep` names the keys left alone, or is nil.
local function ClearProfile(profile, keep)
  for key, value in pairs(profile) do
    if not (keep and keep[key]) then
      if type(value) == "table" then
        for inner in pairs(value) do value[inner] = nil end
      else
        profile[key] = nil
      end
    end
  end
end

-- What is on screen, put onto the settings as they now stand: the second
-- half of both resets, once the first has cleared what it clears.
local function ApplyResetLive()
  ForgetSettings()

  -- The arrange mode closes first: its strip, its card and the grid's
  -- handles were drawn from the arrangement just cleared.
  local arrange = ns.Arrange
  if arrange then ResetStep(arrange.Leave) end

  -- The chosen look's border, border size and opacity. Each Reset re-reads
  -- its value -- absent now, so the default -- and repaints every window the
  -- skin has painted. A style with none of the three has none to repaint.
  local skin = ns.Skin
  if skin then
    ResetStep(skin.ResetBorder)
    ResetStep(skin.ResetBorderSize)
    ResetStep(skin.ResetBgOpacity)
  end

  -- The mail window's content, through the entry points the options use.
  -- The rows re-lay on the default arrangement wherever it applies: the
  -- Mail tab's list in every view, History and another character's box
  -- among them (row layout), the category grid (category buttons), and
  -- Mail Memory's own window (memory.Refresh, below).
  ResetStep(UI.RefreshCollectRowLayout)
  ResetStep(UI.RefreshCollectCategoryButtons)
  ResetStep(UI.RefreshCollectTabCounts)
  ResetStep(UI.RefreshMailTabAttach)
  ResetStep(UI.RefreshMemoryState)
  local panel, collect = CollectPanel(), ns.CollectTab
  if panel and collect then
    -- Read mail back under its divider, unfolded, and History's days --
    -- its view back in the row, if it was off.
    ResetStep(collect.RefreshReadMode, panel)
    ResetStep(collect.RefreshHistoryDays, panel)
  end
  -- The window's size and place last, onto the floor the settings above
  -- have just decided.
  ResetStep(UI.ResetWindowGeometry)

  local memory, icon, manager = ns.MailMemory, ns.MinimapButton, ns.RecipientManager
  if memory then ResetStep(memory.Refresh) end
  if icon then ResetStep(icon.Refresh) end
  if manager then ResetStep(manager.ResetWindow) end
end

-- What stops a reset now: "collect" while Postbox is taking mail out of the
-- box (a collect run, or any sequence holding the mail channel), "send"
-- while a send is under way, nil when nothing is. Both resets wait: a run
-- reads the settings as it goes (what becomes of a read mail, the rows and
-- the grid it repaints) and writes the records Reset everything clears --
-- the History entry of the mail it is taking, the recipient a send saves.
function UI.ResetBlockedBy()
  local collect, mail, send = ns.CollectTab, ns.MailService, ns.SendTab
  if collect and type(collect.IsRunning) == "function" and collect.IsRunning() then return "collect" end
  if mail and type(mail.IsBusy) == "function" and mail.IsBusy() then return "collect" end
  if send and type(send.IsSending) == "function" and send.IsSending() then return "send" end
  return nil
end

-- Clears every setting, then puts what is on screen onto the defaults.
-- Returns true when the window style changed: the one part that waits for a
-- /reload, because the style is claimed once, at login. Refused, clearing
-- nothing, while UI.ResetBlockedBy answers: false, true.
function UI.ResetSettings()
  if UI.ResetBlockedBy() then return false, true end
  local store = ns.Store
  local profile = store and store.Get and store.Get("profile")
  if type(profile) ~= "table" then return false end

  local styleBefore = UI.GetStyleChoice()

  -- Whether the minimap icon is on survives: it is the player's choice of
  -- whether Postbox replaces the game's own new-mail icon at all, not a look,
  -- and a reset that silently brought the game's icon back read as broken.
  -- Everything else about the icon -- its art, size, place -- is reset.
  local minimap = profile.minimap
  local iconOn = type(minimap) == "table" and minimap.enabled or nil

  ClearProfile(profile, RESET_KEEP)
  if iconOn ~= nil and type(minimap) == "table" then minimap.enabled = iconOn end
  ApplyResetLive()

  return UI.GetStyleChoice() ~= styleBefore
end

-- RESET EVERYTHING (the footer's other choice): Postbox as a first install
-- has it, but for the census of the player's own characters.
--
-- Every root of the saved variables (Postbox.lua, SCHEMA) is cleared except
-- the ones in CENSUS_KEEP. The census is facts, not choices: each character
-- writes its own entry only when it logs in, so a census cleared here would
-- stay empty for every alt until that alt was played again -- and From
-- alts, the groups window's list of characters and the Send tab's alts all
-- read it. As with the settings, clearing rather than listing is the point:
-- a root added later is cleared without anyone having to remember it, and
-- one that must survive this goes in CENSUS_KEEP.
--
-- Emptied where they stand, like the settings and for the same reasons: the
-- store has memoised every root (Postbox.lua, EnsureDB) and modules hold
-- theirs. Every root is still a table afterwards, as a first install's are.
local CENSUS_KEEP = {
  alts       = true,  -- realm -> the characters seen logging in
  altClasses = true,  -- realm -> name -> class
  altMeta    = true,  -- realm -> name -> level, faction, last seen
}

-- Clears everything but the census, tells the modules that remember what
-- they read, then puts what is on screen onto the defaults. Returns true
-- when the window style changed, and is refused, as UI.ResetSettings is.
function UI.ResetEverything()
  if UI.ResetBlockedBy() then return false, true end
  local root = PostboxDB
  if type(root) ~= "table" then return false end

  local styleBefore = UI.GetStyleChoice()

  for key, value in pairs(root) do
    if not CENSUS_KEEP[key] then
      if key == "profile" and type(value) == "table" then
        -- Every setting, and this time the recent recipients and the
        -- minimap icon's switch as well. Its own tables stay, emptied:
        -- they are the ones memoised and held (see RESET TO DEFAULTS).
        ClearProfile(value, nil)
      elseif type(value) == "table" then
        for inner in pairs(value) do value[inner] = nil end
      else
        root[key] = nil
      end
    end
  end

  -- What was remembered about the data just cleared. The contact lists,
  -- recent recipients among them, are built afresh on their next read; Mail
  -- Memory's character list and window, and the groups' member sets and
  -- window, are told. The Mail tab comes back to this character's own box:
  -- any other it was showing is gone. The grid, the lists and the windows
  -- are repainted by the re-apply that follows.
  local contacts, memory, groups = ns.ContactService, ns.MailMemory, ns.CharacterGroups
  if contacts then ResetStep(contacts.Invalidate) end
  if memory then ResetStep(memory.DataCleared) end
  if groups then ResetStep(groups.DataCleared) end
  local panel, collect = CollectPanel(), ns.CollectTab
  if panel and collect then ResetStep(collect.RefreshOthers, panel, true) end

  ApplyResetLive()

  -- The recipients last, on the contact lists rebuilt: the manager's list,
  -- when it is open, and the Send tab's favourites count.
  local manager, send = ns.RecipientManager, ns.SendTab
  if manager and type(manager.IsShown) == "function" and manager.IsShown() then
    ResetStep(manager.Refresh, true)
  end
  if send then ResetStep(send.RefreshRecipientBar) end

  return UI.GetStyleChoice() ~= styleBefore
end

-- The window style: which look paints Postbox's windows. A string with its own
-- accessors, like the tab caption below. Read once, at PLAYER_LOGIN, by each
-- skin's claim -- which is why a change needs a /reload and why these accessors
-- never repaint anything themselves.
--   host      the installed host UI's skin (EllesmereUI, or ElvUI)
--   blizzard  the built-in warm-stone Blizzard-native look
--   modern    the first-party flat skin (Core/Skin_Modern.lua)
--
-- This setting now OUTRANKS a host UI. It did not always: the host skin used to
-- win structurally and this value was inert under one. A player who prefers
-- Postbox's own look to the one their UI pack imposes could not say so, which
-- is the whole reason for the change.
--
-- "host" is the default wherever a host is installed, so nothing changes for
-- anyone who does not go looking for this.
local STYLE_CHOICES = { host = true, blizzard = true, modern = true }

local function HostInstalled()
  return (_G.EllesmereUI or _G.ElvUI) and true or false
end
UI.HostInstalled = HostInstalled

function UI.GetStyleChoice()
  local store = ns.Store
  local profile = store and store.Get and store.Get("profile")
  local stored = profile and profile.style

  -- MIGRATION, and the reason this is not just a nil check. Before the setting
  -- could override a host UI it was inert under one, so an existing profile's
  -- "blizzard" or "modern" was never a statement about what that player wanted
  -- while running EllesmereUI -- it is whatever they last picked on a plain UI,
  -- or the old default. Honouring it now would silently strip the host skin
  -- from someone who never asked. Until they choose from the host-aware
  -- control, a detected host wins, which is exactly what they see today.
  if HostInstalled() and not (profile and profile.styleHostAware) then
    return "host"
  end

  if STYLE_CHOICES[stored] then return stored end
  return HostInstalled() and "host" or "blizzard"
end

function UI.SetStyleChoice(style)
  if not STYLE_CHOICES[style] then return end
  local store = ns.Store
  local profile = store and store.EnsurePath and store.EnsurePath("profile")
  if not profile then return end
  profile.style = style
  -- The choice was made with the host in view, so the migration above stops
  -- speaking for this profile from here on.
  profile.styleHostAware = true
end

-- The gate both host skins consult before claiming. Kept here rather than
-- duplicated in each: they claim through different handshakes (EllesmereUI
-- defers behind a watchdog, ElvUI behind a timer) and the one thing they must
-- agree on is whether the player asked for them at all.
function UI.HostSkinAllowed()
  return UI.GetStyleChoice() == "host"
end

-- The Mail tab's caption while the mailbox is open, from "Show counts":
--   on   "Mail (2)"   -- how many still hold something to collect: the same
--                       number the Inbox segment carries
--   off  "Mail •"     -- an accent dot while anything is uncollected
-- It had a dropdown of its own (dot / count / none) beside "Show counts", and
-- two switches over one number read as the count being broken when the
-- caption kept its dot. One switch now; a stored tabCaption is ignored.
--
-- Now the dot either way. The number moved off the window's tab: the Inbox
-- segment right under it counts the whole box and each button what it would
-- collect, and a second copy of one of those on the tab read as a duplicate.
function UI.GetTabCaptionMode()
  return "dot"
end

-- The crafting quality mark, two things a row may wear independently: the
-- badge on the corner of the item's icon (GetQualityIcon: on unless the
-- player turned it off, stored as profile.qualityIcon = false), and a mark
-- beside the item's name (GetQualityName: "before" it, with the room for it
-- kept on every row so the names stay in line; "after" it, as a chat link
-- has it; or "off", the default, stored as nothing).
--
-- They were one choice, profile.qualityMark ("icon", "name" after the name,
-- "both" the icon and after the name, "before", "off"), and before that the
-- rowQuality switch. A profile still holding either is carried over the
-- first time the mark is asked about, to exactly what it drew, and the old
-- keys are dropped: this is the one read here that writes, and only onto a
-- profile that already holds the old key.
local QUALITY_NAMES = { before = true, after = true, off = true }
-- old choice -> the icon's badge, the name's mark
local QUALITY_OLD = {
  icon   = { true,  "off" },
  name   = { false, "after" },
  both   = { true,  "after" },
  before = { false, "before" },
  off    = { false, "off" },
}

local function ReadQuality(memo)
  local profile = memo.profile
  if type(profile) == "table" and (profile.qualityMark ~= nil or profile.rowQuality ~= nil) then
    local old = QUALITY_OLD[profile.qualityMark]
      or (profile.rowQuality == false and QUALITY_OLD.off) or nil
    if old and profile.qualityIcon == nil and profile.qualityName == nil then
      if not old[1] then profile.qualityIcon = false end
      if old[2] ~= "off" then profile.qualityName = old[2] end
    end
    profile.qualityMark, profile.rowQuality = nil, nil
  end
  local icon, name
  if type(profile) == "table" then icon, name = profile.qualityIcon, profile.qualityName end
  memo.qIcon = icon ~= false
  memo.qName = (QUALITY_NAMES[name] and name) or "off"
end

function UI.GetQualityIcon()
  local memo = Settings()
  if memo.qName == nil then ReadQuality(memo) end
  return memo.qIcon
end
function UI.SetQualityIcon(on)
  UI.GetQualityIcon()
  local profile = ns.Store and ns.Store.EnsurePath and ns.Store.EnsurePath("profile")
  if profile then
    if on then profile.qualityIcon = nil else profile.qualityIcon = false end
  end
  ForgetSettings()
end

function UI.GetQualityName()
  local memo = Settings()
  if memo.qName == nil then ReadQuality(memo) end
  return memo.qName
end
function UI.SetQualityName(mode)
  if not QUALITY_NAMES[mode] then return end
  UI.GetQualityName()
  local profile = ns.Store and ns.Store.EnsurePath and ns.Store.EnsurePath("profile")
  if profile then profile.qualityName = (mode ~= "off") and mode or nil end
  ForgetSettings()
end

-- The order a mail row's figures stood in before the row had an arrangement
-- of its own (UI.GetRowLayout, below): an array of the three ids "time",
-- "money" and "slots". Read now only to carry a profile that has never been
-- arranged across unchanged. Anything unreadable -- a missing id, a
-- duplicate, an unknown word -- falls back to the default whole rather than
-- being half-repaired.
local ROW_FIGURES = { time = true, money = true, slots = true }
local ROW_ORDER_DEFAULT = { "time", "money", "slots" }

function UI.GetRowOrder()
  local store = ns.Store
  local stored = store and store.Get and store.Get("profile.rowOrder")
  if type(stored) == "string" then
    local out, seen = {}, {}
    for id in stored:gmatch("[^,]+") do
      if ROW_FIGURES[id] and not seen[id] then
        seen[id] = true
        out[#out + 1] = id
      end
    end
    if #out == 3 then return out end
  end
  return { ROW_ORDER_DEFAULT[1], ROW_ORDER_DEFAULT[2], ROW_ORDER_DEFAULT[3] }
end

-- A column's choices -- which gold a row shows, when it shows the time
-- left, how it writes the slots -- belong to the arrangement the row
-- follows, as its columns do, so each list keeps its own:
--   rows     one-line rows: the Mail tab while Larger mail rows is off,
--            another character's box and Mail Memory (UI.GetRowLayout)
--   large    Larger mail rows (UI.GetLargeLayout)
--   history  History (UI.GetHistoryLayout)
-- The accessors take that word, as the arrange mode's AR.ListKind names
-- the list and each arrangement's table carries it (`arrangement`, below);
-- none is the one-line rows'.
--
-- Each is kept under its arrangement's own key, the layout's prefix and
-- the choice: rowGoldMode, largeGoldMode, historyGoldMode; rowExpiryWhen,
-- largeExpiryWhen; rowSlotsStyle. (rowGoldMode is not rowGold, the switch
-- the gold column had before it was arranged.) They were one choice for
-- every list, goldMode, expiryWhen and slotsStyle: an arrangement with
-- nothing of its own stored reads that one, so a profile carries across
-- unchanged, and a write to one arrangement never moves another's. The
-- shared keys are only read, as the old row switches are, so a profile
-- taken back to an older version still has them. A default is stored as
-- nothing only while there is no shared value it would read instead.
--
-- History has no time left and no slots; a Larger row writes its slots in
-- words, on its second line as in its tooltip, so the slots' choice is the
-- one-line rows' alone.
do
  local GOLD_MODES = { both = true, earned = true, spent = true }
  local GOLD_KEY = { rows = "rowGoldMode", large = "largeGoldMode", history = "historyGoldMode" }
  -- "always", or under "7", "3" or "1" days. Always by default: a column
  -- that fills in only for some mails reads as missing data to someone who
  -- never chose the threshold.
  local EXPIRY_WHEN = { always = true, ["7"] = true, ["3"] = true, ["1"] = true }
  local EXPIRY_KEY = { rows = "rowExpiryWhen", large = "largeExpiryWhen" }

  -- The arrangement's own value, else the shared one it had before.
  local function Stored(key, shared)
    local store = ns.Store
    local profile = store and store.Get and store.Get("profile")
    if type(profile) ~= "table" then return nil end
    local value = profile[key]
    if value == nil then value = profile[shared] end
    return value
  end

  local function Keep(key, shared, value, default)
    local store = ns.Store
    local profile = store and store.EnsurePath and store.EnsurePath("profile")
    if profile then
      if value == default and profile[shared] == nil then value = nil end
      profile[key] = value
    end
    ForgetSettings()
  end

  -- Which gold the rows show while Gold is on: "both", "earned" or "spent".
  function UI.GetGoldMode(arrangement)
    local key = GOLD_KEY[arrangement] or GOLD_KEY.rows
    local memo = Settings().gold
    local mode = memo[key]
    if mode then return mode end
    mode = Stored(key, "goldMode")
    if not GOLD_MODES[mode] then mode = "both" end
    memo[key] = mode
    return mode
  end
  function UI.SetGoldMode(mode, arrangement)
    if not GOLD_MODES[mode] then return end
    Keep(GOLD_KEY[arrangement] or GOLD_KEY.rows, "goldMode", mode, "both")
  end

  -- When the rows show the time left. nil sets the default.
  function UI.GetExpiryWhen(arrangement)
    local key = EXPIRY_KEY[arrangement] or EXPIRY_KEY.rows
    local memo = Settings().expiry
    local when = memo[key]
    if when then return when end
    when = Stored(key, "expiryWhen")
    if not EXPIRY_WHEN[when] then when = "always" end
    memo[key] = when
    return when
  end
  function UI.SetExpiryWhen(when, arrangement)
    if when ~= nil and not EXPIRY_WHEN[when] then return end
    Keep(EXPIRY_KEY[arrangement] or EXPIRY_KEY.rows, "expiryWhen", when or "always", "always")
  end

  -- How a one-line row writes the slots a mail still holds in its column:
  -- "words" ("4 slots", the default) or "number" ("4"). nil sets the
  -- default. Remembered with the other row settings (ForgetSettings).
  function UI.GetSlotsStyle()
    local memo = Settings()
    if memo.slots then return memo.slots end
    memo.slots = (Stored("rowSlotsStyle", "slotsStyle") == "number") and "number" or "words"
    return memo.slots
  end
  function UI.SetSlotsStyle(style)
    if style ~= nil and style ~= "words" and style ~= "number" then return end
    Keep("rowSlotsStyle", "slotsStyle", style or "words", "words")
  end
end

-- How a one-line row's figures stand (CollectTab, RV.Place), in the Mail
-- tab, History and Mail Memory alike: "columns" (the default), every figure
-- in its own column on every row, gold under gold, a subject running on
-- through the columns its mail leaves empty; or "packed", each row closing
-- its gaps away from the subject -- the columns after it toward the row's
-- right edge, those before it toward its left -- and the subject given the
-- room. Stored only when packed (profile.rowPacking), so nothing stored is
-- columns. It was the lineUpColumns switch, false meaning packed: the first
-- read of a profile that still has it carries it over and drops it.
-- Remembered with the other row settings (ForgetSettings).
function UI.GetRowPacking()
  local memo = Settings()
  if memo.packing then return memo.packing end
  local store = ns.Store
  local profile = store and store.Get and store.Get("profile")
  if type(profile) == "table" and profile.lineUpColumns ~= nil then
    if profile.lineUpColumns == false and profile.rowPacking == nil then profile.rowPacking = "packed" end
    profile.lineUpColumns = nil
  end
  local stored = type(profile) == "table" and profile.rowPacking or nil
  memo.packing = (stored == "packed") and "packed" or "columns"
  return memo.packing
end
function UI.SetRowPacking(mode)
  if mode ~= nil and mode ~= "columns" and mode ~= "packed" then return end
  local profile = ns.Store and ns.Store.EnsurePath and ns.Store.EnsurePath("profile")
  if profile then
    profile.rowPacking = (mode == "packed") and "packed" or nil
    profile.lineUpColumns = nil
  end
  ForgetSettings()
end

-- What happens to read mail with nothing left in it: "fold", listed after
-- the inbox under a divider (the default); "tab", listed under a Done
-- segment of its own; "delete", deleted the moment Postbox empties it or
-- the reading view closes on it -- History keeps what it said.
local READ_MODES = { fold = true, tab = true, delete = true }
function UI.GetReadMode()
  local stored = ns.Store and ns.Store.Get and ns.Store.Get("profile.readMail")
  return READ_MODES[stored] and stored or "fold"
end
function UI.SetReadMode(mode)
  if not READ_MODES[mode] then return end
  local profile = ns.Store and ns.Store.EnsurePath and ns.Store.EnsurePath("profile")
  if profile then profile.readMail = mode end
  local panel, collect = CollectPanel(), ns.CollectTab
  if panel and collect and collect.RefreshReadMode then collect.RefreshReadMode(panel) end
end

-- What resting the pointer on the item icon of a mail holding several items
-- shows (CollectTab, the fan): "tooltip", the list of them (the default), or
-- "fan", the items spread out beside the icon, each taken by a click. One
-- behaviour for the Mail tab's rows, not a part of any arrangement. Stored
-- only when it is the fan, so nothing stored is the tooltip. Read on hover,
-- never on a bind, so it keeps no memo.
function UI.GetAttachHover()
  local stored = ns.Store and ns.Store.Get and ns.Store.Get("profile.attachHover")
  return (stored == "fan") and "fan" or "tooltip"
end
function UI.SetAttachHover(mode)
  if mode ~= nil and mode ~= "tooltip" and mode ~= "fan" then return end
  local profile = ns.Store and ns.Store.EnsurePath and ns.Store.EnsurePath("profile")
  if profile then profile.attachHover = (mode == "fan") and "fan" or nil end
  -- An open fan goes when the tooltip is chosen instead.
  local collect = ns.CollectTab
  if mode ~= "fan" and collect and collect.CloseFan then collect.CloseFan() end
end

-- How many days History keeps: 7 by default, up to 30. 0 is "Never", which
-- turns History off: nothing is recorded, every character's record is
-- emptied the moment it is chosen, and its view leaves the Mail tab
-- (Core/MailMemory.lua 2c, CT.RefreshHistoryDays).
local HISTORY_DAYS = { [0] = true, [7] = true, [14] = true, [21] = true, [30] = true }
function UI.GetHistoryDays()
  local stored = tonumber(ns.Store and ns.Store.Get and ns.Store.Get("profile.historyDays"))
  return (stored and HISTORY_DAYS[stored]) and stored or 7
end
function UI.SetHistoryDays(days)
  days = tonumber(days)
  if not (days and HISTORY_DAYS[days]) then return end
  local profile = ns.Store and ns.Store.EnsurePath and ns.Store.EnsurePath("profile")
  if profile then profile.historyDays = tostring(days) end
  -- "Never" keeps nothing from the moment it is chosen: every character's
  -- record goes now, not at the next login. Once stored, so the pruning
  -- reads 0 days; a record already empty makes this a lookup.
  if days == 0 then
    local memory = ns.MailMemory
    if memory and type(memory.PruneAllHistory) == "function" then pcall(memory.PruneAllHistory) end
  end
  local panel, collect = CollectPanel(), ns.CollectTab
  if panel and collect and collect.RefreshHistoryDays then collect.RefreshHistoryDays(panel) end
end

-- What the Send tab keeps once a mail has gone: "nothing" (the default: a
-- cleared form, so a name left standing cannot send the next mail to the
-- wrong person), "recipient", or "subject" -- the recipient and the subject,
-- for a run of mails to one bank alt. Stored only when it is not nothing.
-- The old switch, profile.keepRecipient, read as "recipient" until a choice
-- is made here, which is when it is dropped. Read once per send, so no memo.
local AFTER_SEND_KEEP = { recipient = true, subject = true }
function UI.GetAfterSendKeep()
  local profile = ns.Store and ns.Store.Get and ns.Store.Get("profile")
  if type(profile) ~= "table" then return "nothing" end
  local stored = profile.afterSendKeep
  if AFTER_SEND_KEEP[stored] then return stored end
  if stored == nil and profile.keepRecipient == true then return "recipient" end
  return "nothing"
end
function UI.SetAfterSendKeep(mode)
  if mode ~= "nothing" and not AFTER_SEND_KEEP[mode] then return end
  local profile = ns.Store and ns.Store.EnsurePath and ns.Store.EnsurePath("profile")
  if not profile then return end
  profile.afterSendKeep = AFTER_SEND_KEEP[mode] and mode or nil
  profile.keepRecipient = nil
end

-- Performance recording for the bug report (Postbox.lua, 5b): "off" (the
-- default), "on" or "detail". Saved, because the open a report is wanted for
-- is often the first after a /reload. This pair only reads and stores: the
-- record follows the choice through ns.SetPerfRecording, which is the way to
-- change it.
local PERF_RECORD = { off = true, on = true, detail = true }
function UI.GetPerfRecord()
  local stored = ns.Store and ns.Store.Get and ns.Store.Get("profile.perfRecord")
  return PERF_RECORD[stored] and stored or "off"
end
function UI.SetPerfRecord(mode)
  if not PERF_RECORD[mode] then return end
  local profile = ns.Store and ns.Store.EnsurePath and ns.Store.EnsurePath("profile")
  if profile then profile.perfRecord = mode end
end

-- A mail row's columns: which it shows, and in what order, left to right.
-- One string on the profile -- "read,icon,sender,subject,time,money,slots",
-- a leading "-" on a column it hides -- and one arrangement for every list
-- that draws mail: the Mail tab in both row sizes and Mail Memory in both
-- windows. History has one of its own (UI.GetHistoryLayout, below). Both
-- are arranged in the window itself (Core/Arrange.lua). The subject is the
-- one column that cannot be hidden: it takes whatever room the others
-- leave.
--
-- A profile that has never been arranged reads exactly as it did under the
-- three switches and the figure order it had before (rowGold, rowSlots,
-- rowExpiry, rowOrder): the name columns first, then the figures in their
-- order, each hidden where its switch was off. Those keys are only read, so
-- a profile taken back to an older version still has them.
--
-- Anything unreadable -- a missing column, a duplicate, an unknown word -- is
-- not half-repaired: the old keys decide, and failing those the default.
--
-- The answer is shared and must not be written to: { {id=, shown=}, ...,
-- shown = { [id] = bool }, arrangement = "rows" } -- "large" and "history"
-- on the other two, so a row's choices go with its columns. It is kept until one of the keys it was read
-- from changes, so the row binder can ask on every row for the price of a
-- few field reads -- and a profile cleared from under it is noticed.
local ROW_COLUMNS = { "read", "icon", "sender", "subject", "time", "money", "slots" }
local ROW_COLUMN_KNOWN = {}
for i = 1, #ROW_COLUMNS do ROW_COLUMN_KNOWN[ROW_COLUMNS[i]] = true end
local ROW_LAYOUT_DEFAULT = "read,icon,sender,subject,time,money,slots"
-- The switch each figure had before it had a place in the arrangement.
local LEGACY_SWITCH = { time = "rowExpiry", money = "rowGold", slots = "rowSlots" }

-- An arrangement's string read against the columns its list has (`known`,
-- `count` of them: the mail rows' above, or History's below).
local function ParseLayout(text, known, count)
  if type(text) ~= "string" then return nil end
  local out, seen = { shown = {} }, {}
  for token in text:gmatch("[^,]+") do
    local hidden = token:sub(1, 1) == "-"
    local id = hidden and token:sub(2) or token
    if not known[id] or seen[id] then return nil end
    seen[id] = true
    local shown = (not hidden) or id == "subject"
    out[#out + 1] = { id = id, shown = shown }
    out.shown[id] = shown
  end
  if #out ~= count then return nil end
  return out
end

local function ParseRowLayout(text)
  return ParseLayout(text, ROW_COLUMN_KNOWN, #ROW_COLUMNS)
end

-- History's columns (UI.GetHistoryLayout, below).
local HISTORY_COLUMNS = { "age", "icon", "sender", "subject", "money" }
local HISTORY_COLUMN_KNOWN = {}
for i = 1, #HISTORY_COLUMNS do HISTORY_COLUMN_KNOWN[HISTORY_COLUMNS[i]] = true end
local HISTORY_LAYOUT_DEFAULT = "age,icon,sender,subject,money"

local function ParseHistoryLayout(text)
  return ParseLayout(text, HISTORY_COLUMN_KNOWN, #HISTORY_COLUMNS)
end

-- An arrangement written as its string, or nil where it does not read back
-- (`parse`: the list's own reader).
local function FormatLayout(layout, parse)
  if type(layout) ~= "table" then return nil end
  local parts = {}
  for i = 1, #layout do
    local entry = layout[i]
    local id = type(entry) == "table" and entry.id or nil
    if not id then return nil end
    parts[#parts + 1] = ((entry.shown == false and id ~= "subject") and "-" or "") .. id
  end
  local text = table.concat(parts, ",")
  return parse(text) and text or nil
end

local function FormatRowLayout(layout)
  return FormatLayout(layout, ParseRowLayout)
end

-- What an unarranged profile's rows showed: the names, then the figures in
-- the old order, each with its old switch (unset was on).
local function LegacyRowLayout(profile)
  local order = UI.GetRowOrder()
  local parts = { "read", "icon", "sender", "subject" }
  for i = 1, #order do
    local id = order[i]
    -- Not `profile and profile[...] or nil`: the switch is false exactly
    -- when it matters.
    local switch = nil
    if type(profile) == "table" then switch = profile[LEGACY_SWITCH[id]] end
    parts[#parts + 1] = ((switch ~= nil and switch ~= true) and "-" or "") .. id
  end
  return table.concat(parts, ",")
end

local rowLayoutMemo = {}

-- Read through the settings memo above (UI.GetRowLayout, below): this one is
-- asked only after a write, and keeps the answer's identity when a write left
-- the arrangement's own keys as they were.
local function ReadRowLayout()
  local store = ns.Store
  local profile = store and store.Get and store.Get("profile")
  if type(profile) ~= "table" then profile = nil end
  local a = profile and profile.rowLayout
  local b = profile and profile.rowOrder
  local c = profile and profile.rowExpiry
  local d = profile and profile.rowGold
  local e = profile and profile.rowSlots
  local memo = rowLayoutMemo
  if memo.layout and memo.a == a and memo.b == b and memo.c == c and memo.d == d and memo.e == e then
    return memo.layout
  end
  memo.a, memo.b, memo.c, memo.d, memo.e = a, b, c, d, e
  memo.layout = ParseRowLayout(a) or ParseRowLayout(LegacyRowLayout(profile))
    or ParseRowLayout(ROW_LAYOUT_DEFAULT)
  -- Which arrangement it is, for the choices a row reads with it (UI.GetGoldMode).
  memo.layout.arrangement = "rows"
  return memo.layout
end

function UI.GetRowLayout()
  local memo = Settings()
  local layout = memo.layout
  if not layout then
    layout = ReadRowLayout()
    memo.layout = layout
  end
  return layout
end

-- layout: { {id=, shown=}, ... } in the new order, or nil for the default.
-- History's rows and Larger mail rows follow this arrangement until each
-- has one stored (UI.GetHistoryLayout, UI.GetLargeLayout): what they show
-- is stored for them first, so arranging the one-line rows never moves
-- theirs.
function UI.SetRowLayout(layout)
  local text = (layout == nil) and ROW_LAYOUT_DEFAULT or FormatRowLayout(layout)
  if not text then return false end
  local profile = ns.Store and ns.Store.EnsurePath and ns.Store.EnsurePath("profile")
  if not profile then return false end
  if profile.historyLayout == nil then
    profile.historyLayout = FormatLayout(UI.GetHistoryLayout(), ParseHistoryLayout)
  end
  if profile.largeLayout == nil then
    profile.largeLayout = FormatRowLayout(UI.GetLargeLayout())
  end
  profile.rowLayout = text
  ForgetSettings()
  return true
end

-- Larger mail rows' columns: an arrangement of their own, in the one-line
-- rows' string ("read,icon,sender,subject,time,money,slots", a leading "-"
-- on a hidden column), arranged when the arrange mode is opened over the
-- Mail tab while its rows are the two-line ones. A two-line row reads from
-- it only what it can show (CollectTab's RV.Place): which side of the
-- subject the read mark and the icon stand on, and their order there; the
-- sender before the subject, at the end of the first line, or -- where a
-- figure stands between the two in the order -- on the second line among
-- the figures; the figures' order along the second line; what is hidden.
--
-- Nothing stored reads as the two-line rows drew the one-line rows'
-- arrangement until now: the same order, with a sender that stood beyond a
-- figure moved beside the subject on its own side, which is where those
-- rows drew it. The first change to the one-line rows' arrangement stores
-- it (UI.SetRowLayout), so from then on each size keeps its own. Shared and
-- read-only, and kept until the keys it was read from change, as the
-- others are.
do
  local largeLayoutMemo = {}

  -- The one-line rows' arrangement as a two-line row drew it (above).
  local function DeriveLarge(rows)
    local s, d = nil, nil
    for i = 1, #rows do
      if rows[i].id == "subject" then s = i elseif rows[i].id == "sender" then d = i end
    end
    local between = false
    if s and d then
      for i = math.min(s, d) + 1, math.max(s, d) - 1 do
        if ROW_FIGURES[rows[i].id] then between = true end
      end
    end
    local parts = {}
    local senderToken = d and ((rows[d].shown and "" or "-") .. "sender") or nil
    for i = 1, #rows do
      local id = rows[i].id
      local token = (rows[i].shown and "" or "-") .. id
      if between and id == "subject" then
        if d < s then parts[#parts + 1] = senderToken end
        parts[#parts + 1] = token
        if d > s then parts[#parts + 1] = senderToken end
      elseif not (between and id == "sender") then
        parts[#parts + 1] = token
      end
    end
    return table.concat(parts, ",")
  end

  local function ReadLargeLayout()
    local store = ns.Store
    local profile = store and store.Get and store.Get("profile")
    local a = type(profile) == "table" and profile.largeLayout or nil
    local rows = (a == nil) and UI.GetRowLayout() or nil
    local memo = largeLayoutMemo
    if memo.layout and memo.a == a and memo.rows == rows then return memo.layout end
    memo.a, memo.rows = a, rows
    memo.layout = ParseRowLayout(a) or (rows and ParseRowLayout(DeriveLarge(rows)))
      or ParseRowLayout(ROW_LAYOUT_DEFAULT)
    memo.layout.arrangement = "large"
    return memo.layout
  end

  function UI.GetLargeLayout()
    local memo = Settings()
    local layout = memo.large
    if not layout then
      layout = ReadLargeLayout()
      memo.large = layout
    end
    return layout
  end

  -- layout: { {id=, shown=}, ... } in the new order, or nil for the default.
  function UI.SetLargeLayout(layout)
    local text = (layout == nil) and ROW_LAYOUT_DEFAULT or FormatRowLayout(layout)
    if not text then return false end
    local profile = ns.Store and ns.Store.EnsurePath and ns.Store.EnsurePath("profile")
    if not profile then return false end
    profile.largeLayout = text
    ForgetSettings()
    return true
  end
end

-- Whether a mail row shows this column (an id from ROW_COLUMNS).
function UI.RowColumnShown(id)
  return UI.GetRowLayout().shown[id] == true
end

-- History's columns: the age it was collected, first by default, then the
-- mail rows' columns History has -- the icon, the sender, what came out
-- (the subject) and the money; no read mark, no time left, no slots. Its
-- own string, as the mail rows' is ("age,icon,sender,subject,money", a
-- leading "-" on a hidden column), arranged when the arrange mode is
-- opened over History.
--
-- Nothing stored reads as what History showed before it had one: the age
-- first, then the mail rows' arrangement in its order and with its hidden
-- columns, less the ones History has not -- on a profile that never
-- arranged anything, the default. The first write to the mail rows'
-- arrangement stores it (UI.SetRowLayout), so from then on History keeps
-- its own.
--
-- The answer is shared and must not be written to, as the mail rows' is,
-- and kept until the keys it was read from change.
local historyLayoutMemo = {}

-- Read through the settings memo (UI.GetHistoryLayout): after a write only.
local function ReadHistoryLayout()
  local store = ns.Store
  local profile = store and store.Get and store.Get("profile")
  local a = type(profile) == "table" and profile.historyLayout or nil
  local rows = (a == nil) and UI.GetRowLayout() or nil
  local memo = historyLayoutMemo
  if memo.layout and memo.a == a and memo.rows == rows then return memo.layout end
  memo.a, memo.rows = a, rows
  local layout = ParseHistoryLayout(a)
  if not layout and rows then
    local parts = { "age" }
    for i = 1, #rows do
      local id = rows[i].id
      if HISTORY_COLUMN_KNOWN[id] then parts[#parts + 1] = (rows[i].shown and "" or "-") .. id end
    end
    layout = ParseHistoryLayout(table.concat(parts, ","))
  end
  memo.layout = layout or ParseHistoryLayout(HISTORY_LAYOUT_DEFAULT)
  memo.layout.arrangement = "history"
  return memo.layout
end

function UI.GetHistoryLayout()
  local memo = Settings()
  local layout = memo.history
  if not layout then
    layout = ReadHistoryLayout()
    memo.history = layout
  end
  return layout
end

-- layout: { {id=, shown=}, ... } in the new order, or nil for the default.
function UI.SetHistoryLayout(layout)
  local text = (layout == nil) and HISTORY_LAYOUT_DEFAULT or FormatLayout(layout, ParseHistoryLayout)
  if not text then return false end
  local profile = ns.Store and ns.Store.EnsurePath and ns.Store.EnsurePath("profile")
  if not profile then return false end
  profile.historyLayout = text
  ForgetSettings()
  return true
end

-- How History writes when a mail was collected: how long ago, "plain"
-- ("3d"), "short" ("3d ago", the default) or "long" ("3 days ago"); or
-- the day it was, "date_dm" ("30 Sep", the day first) or "date_md" ("Sep
-- 30", the month first), or in numbers, "num_dm" ("30/09") or "num_md"
-- ("09/30"). Stored as its word but for short, so nothing stored is short.
-- Remembered with the other row settings.
--
-- The two kinds, how long ago ("ago") and the day ("date"), each with its
-- own formats, the first of each list its default. Switching kind brings
-- back the format that kind last had: the one left behind is kept as
-- profile.historyAgeOther, nothing while it is its kind's default, and
-- cleared with the choice by a reset (SetHistoryAge(nil)).
local HISTORY_AGES = { plain = "ago", short = "ago", long = "ago",
  date_dm = "date", date_md = "date", num_dm = "date", num_md = "date" }
UI.HISTORY_AGE_KINDS = {
  ago  = { "plain", "short", "long" },
  date = { "date_dm", "date_md", "num_dm", "num_md" },
}
local HISTORY_AGE_FIRST = { ago = "short", date = "date_dm" }
function UI.GetHistoryAge()
  local memo = Settings()
  if memo.age then return memo.age end
  local stored = ns.Store and ns.Store.Get and ns.Store.Get("profile.historyAge")
  memo.age = (HISTORY_AGES[stored] and stored) or "short"
  return memo.age
end
function UI.SetHistoryAge(style)
  if style ~= nil and not HISTORY_AGES[style] then return end
  local profile = ns.Store and ns.Store.EnsurePath and ns.Store.EnsurePath("profile")
  if profile then
    if style == nil then
      profile.historyAgeOther = nil
    else
      local was = UI.GetHistoryAge()
      local kind = HISTORY_AGES[was]
      if kind ~= HISTORY_AGES[style] then
        profile.historyAgeOther = (was ~= HISTORY_AGE_FIRST[kind]) and was or nil
      end
    end
    profile.historyAge = (style ~= "short") and style or nil
  end
  ForgetSettings()
end
-- The kind shown now, "ago" or "date".
function UI.GetHistoryAgeKind()
  return HISTORY_AGES[UI.GetHistoryAge()] or "ago"
end
-- The format a kind would show: the one on screen if it is that kind's,
-- else the one it last had, else its first.
function UI.HistoryAgeFor(kind)
  local current = UI.GetHistoryAge()
  if HISTORY_AGES[current] == kind then return current end
  local kept = ns.Store and ns.Store.Get and ns.Store.Get("profile.historyAgeOther")
  if HISTORY_AGES[kept] == kind then return kept end
  return HISTORY_AGE_FIRST[kind]
end
function UI.SetHistoryAgeKind(kind)
  if not HISTORY_AGE_FIRST[kind] or UI.GetHistoryAgeKind() == kind then return end
  UI.SetHistoryAge(UI.HistoryAgeFor(kind))
end

-- The category buttons under the list: their order and which are hidden, as
-- "bought,sold,-canceled,...". The ids are CollectTab's built-in sweeps and
-- "group:<key>" for a character group's own button (ns.CharacterGroups).
-- Only the stored list is read here; which of those ids still exist, and
-- where a new one goes, is the grid's to decide (CollectTab, "The category
-- grid"), because only the grid knows what can be shown. An id is written
-- with its commas and percent signs escaped, so a group's key can be
-- anything. Unset or unreadable is the default: every button, in the grid's
-- own order.
local function GridEscape(id)
  return (id:gsub("%%", "%%25"):gsub(",", "%%2C"))
end

local function GridUnescape(text)
  return (text:gsub("%%2C", ","):gsub("%%25", "%%"))
end

-- The answer is shared, like the row arrangement's, and must not be written
-- to: it is the same table for as long as the stored string is the same one
-- (the settings memo above, and the string itself compared, since the grid
-- asks for it on every list refresh).
function UI.GetGridLayout()
  local memo = Settings()
  local stored = ns.Store and ns.Store.Get and ns.Store.Get("profile.gridLayout")
  if memo.grid and memo.gridText == stored then return memo.grid end
  local out = {}
  if type(stored) == "string" then
    local seen = {}
    for token in stored:gmatch("[^,]+") do
      local hidden = token:sub(1, 1) == "-"
      local id = GridUnescape(hidden and token:sub(2) or token)
      if id ~= "" and not seen[id] then
        seen[id] = true
        out[#out + 1] = { id = id, shown = not hidden }
      end
    end
  end
  memo.grid, memo.gridText = out, stored
  return out
end

-- Whether the arrangement hides the category button `id` ("bought",
-- "group:<key>"...): its stored entry says so. An id it does not name is
-- shown, as the grid places any id it has not seen.
function UI.GridIdHidden(id)
  local layout = UI.GetGridLayout()
  for i = 1, #layout do
    if layout[i].id == id then return layout[i].shown == false end
  end
  return false
end

-- list: { {id=, shown=}, ... }, or nil to forget the arrangement.
function UI.SetGridLayout(list)
  local profile = ns.Store and ns.Store.EnsurePath and ns.Store.EnsurePath("profile")
  if not profile then return end
  if type(list) ~= "table" then
    profile.gridLayout = nil
    ForgetSettings()
    return
  end
  local parts = {}
  for i = 1, #list do
    local entry = list[i]
    if type(entry) == "table" and type(entry.id) == "string" and entry.id ~= "" then
      parts[#parts + 1] = (entry.shown == false and "-" or "") .. GridEscape(entry.id)
    end
  end
  profile.gridLayout = table.concat(parts, ",")
  ForgetSettings()
end

-- The blocks under the Mail tab's list, top down: the totals ("band"), the
-- full-width All mail ("all") and the category buttons ("grid"), as
-- "band,all,grid". Moved in the arrange mode (CollectTab, "The blocks under
-- the list"). Unset -- as Reset leaves it -- or unreadable (a block missing
-- or repeated, an unknown word) is the default order, so it never needs
-- seeding. The answer is shared, like the grid's, and must not be written
-- to: the same table for as long as the stored string is the same one.
local STACK_BLOCKS = { band = true, all = true, grid = true }
local STACK_DEFAULT = { "band", "all", "grid" }

function UI.GetStackOrder()
  local memo = Settings()
  local stored = ns.Store and ns.Store.Get and ns.Store.Get("profile.stackOrder")
  if memo.stack and memo.stackText == stored then return memo.stack end
  local out
  if type(stored) == "string" then
    out = {}
    for id in stored:gmatch("[^,]+") do
      if not STACK_BLOCKS[id] then out = nil break end
      for i = 1, #out do
        if out[i] == id then out = nil break end
      end
      if not out then break end
      out[#out + 1] = id
    end
    if out and #out ~= #STACK_DEFAULT then out = nil end
  end
  memo.stack, memo.stackText = out or STACK_DEFAULT, stored
  return memo.stack
end

-- order: the three ids in their new order, or nil for the default. The
-- default is stored as nothing at all.
function UI.SetStackOrder(order)
  local profile = ns.Store and ns.Store.EnsurePath and ns.Store.EnsurePath("profile")
  if not profile then return end
  local text
  if type(order) == "table" and #order == #STACK_DEFAULT then
    local seen, same = {}, true
    for i = 1, #order do
      local id = order[i]
      if not STACK_BLOCKS[id] or seen[id] then return end
      seen[id] = true
      if id ~= STACK_DEFAULT[i] then same = false end
    end
    if not same then text = table.concat(order, ",") end
  elseif order ~= nil then
    return
  end
  profile.stackOrder = text
  ForgetSettings()
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

-- Somebody else's SetAlpha on MailFrame, and the answer to it.
--
-- Reported from the wild: a player with a mail notifier, a bag addon, a UI
-- pack and a few more all loaded saw Blizzard's mail window standing beside
-- Postbox's -- the native frame at full alpha with ours docked over it. The
-- only thing that can undo the alpha above is another SetAlpha, so that is
-- what is watched: a post-hook, which runs after the caller's call has
-- completed and never touches the caller's execution. While Postbox's window
-- is up, an alpha that is not zero is put back to zero on the spot, and the
-- addon on the stack at the time is written down ONCE for the diagnostic
-- report -- so the next report of this names the culprit instead of the
-- symptom. Idle in every session where nothing fights: the hook costs one
-- comparison per SetAlpha call on a frame nothing calls SetAlpha on.
--
-- The guard is against our own reassert re-entering the hook, not against a
-- loop with the other addon: their next call is their business, and answered
-- the same way.
local alphaHooked = false
local reasserting = false
local ADDON_NAME = "Postbox"

-- The first addon folder on the stack that is not this one.
local function AddonOnStack(stack)
  for folder in string.gmatch(stack or "", "AddOns[/\\]([^/\\]+)[/\\]") do
    if folder ~= ADDON_NAME then return folder end
  end
  return nil
end

local function OnNativeAlphaSet(frame, alpha)
  if reasserting then return end
  if (tonumber(alpha) or 0) == 0 then return end
  if not UI._state.mailboxOpen or not UI._state.visible then return end

  UI._state.alphaFights = (UI._state.alphaFights or 0) + 1
  if not UI._state.alphaCulprit and type(debugstack) == "function" then
    -- Skip this hook and the secure wrapper that called it; a few frames of
    -- caller is enough to find the folder.
    local ok, stack = pcall(debugstack, 3, 6, 0)
    UI._state.alphaCulprit = (ok and AddonOnStack(stack)) or "unknown"
  end

  reasserting = true
  frame:SetAlpha(0)
  reasserting = false
end

local function HideNativeMailFrame()
  if not (MailFrame and type(MailFrame.SetAlpha) == "function") then return end
  MailFrame:SetAlpha(0)
  if not alphaHooked and type(hooksecurefunc) == "function" then
    alphaHooked = true
    hooksecurefunc(MailFrame, "SetAlpha", OnNativeAlphaSet)
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
  -- What the outcome reports, where it is something that can stop being true
  -- by itself: "bags" for a run's "Bags full: N left", which comes down when
  -- the bags have room (UI.OnBagsFullChanged). nil for an ordinary outcome.
  -- outcomeAfter is the line once it has; read only while outcomeKind is set.
  outcomeKind = nil, outcomeAfter = nil,
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
  status.outcomeKind = nil
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
    status.outcome, status.outcomeTone, status.outcomeKind = nil, nil, nil
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
  status.outcomeKind = nil
  if type(text) == "string" and text ~= "" then
    status.outcome, status.outcomeTone = text, tone
  else
    status.outcome, status.outcomeTone = nil, nil
  end
  RenderStatus()
end

-- Says what the outcome just set reports, where it can stop being true by
-- itself ("bags": see status.outcomeKind), and what the line reads once it
-- has (`after`: the same outcome without that part, or nil for nothing).
-- Called right after SetStatusOutcome; a later outcome, activity or clear
-- forgets it.
function UI.TagStatusOutcome(kind, after)
  if status.outcome then status.outcomeKind, status.outcomeAfter = kind, after end
end

function UI.ClearStatus()
  status.activity, status.activityTone = nil, nil
  status.outcome, status.outcomeTone, status.outcomeKind = nil, nil, nil
  RenderStatus()
end

-- The domain's bags-full state (Core/MailService.lua, "Bags full") was set,
-- or has cleared because the bags have room. The buttons count again -- the
-- mails with items leave their counts while it holds and return when it
-- clears -- and the status line follows: a run's "Bags full: N left" comes
-- down with the state, since what it said is no longer so, and the rest of
-- the outcome stays ("Collected: 41"), as it would read after a clean run.
function UI.OnBagsFullChanged()
  local mail = ns.MailService
  local full = mail and type(mail.BagsFull) == "function" and mail.BagsFull()
  if not full and status.outcomeKind == "bags" then
    status.outcome, status.outcomeTone, status.outcomeKind = status.outcomeAfter, nil, nil
  end
  local collect = ns.CollectTab
  if collect and type(collect.RequestRefresh) == "function" then collect.RequestRefresh(CollectPanel()) end
  UI.UpdateStatusSummary()
end

-- Recomputes the idle line and repaints. Safe to call from anywhere at any time:
-- it only ever touches the lowest-priority layer, so it cannot overwrite a run's
-- activity or its outcome.
--
-- Says two things, each only when it is true: the bags are full and mail with
-- items is waiting for room ("Bags full: 6 left"), and some mail in this inbox
-- will not come out ("Stuck: 2"). A mail the server refused this visit still
-- counts as to-collect on the segment above, and trying again will not empty
-- it until whatever the game objected to is dealt with -- which is precisely
-- the fact a count cannot carry. Both count mails, one per inbox index.
-- Everything healthy renders as nothing at all.
--
-- No extra event traffic: this rides the same MAIL_INBOX_UPDATE the counts
-- already follow, and the domain answers 0 without touching the inbox whenever
-- nothing has been refused and the bags are not full.
function UI.UpdateStatusSummary()
  AdoptForeignText()

  status.summary = nil
  local mail = ns.MailService
  local stuck = (mail and type(mail.StuckCount) == "function" and mail.StuckCount()) or 0
  local waiting = (mail and type(mail.BagsFull) == "function" and mail.BagsFull()
    and type(mail.BagsWaiting) == "function" and mail.BagsWaiting()) or 0
  -- Inline escapes rather than a tone: RenderStatus paints the whole label
  -- one colour from the layer that won, and this layer has no tone of its own
  -- to pass. Colouring the text itself keeps the warning with the warning.
  local theme = ns.Theme
  local colorize = theme and theme.Colorize
  if waiting > 0 then
    local text = LF("STATUS_BAGS_FULL", waiting)
    if colorize then text = colorize("warning", text) end
    status.summary = text
  end
  if stuck > 0 then
    local text = LF("STATUS_STUCK", stuck)
    -- In the accent while it is filtering the inbox: a pressed control, not
    -- a warning, for as long as the list shows only these.
    local panel = CollectPanel()
    local filtering = ns.CollectTab and ns.CollectTab.StuckFilterOn and ns.CollectTab.StuckFilterOn(panel)
    if colorize then text = colorize(filtering and "accent" or "warning", text) end
    -- After the bags, em dash between: the bags line is the one a player acts
    -- on first, and it clears by itself.
    status.summary = status.summary and (status.summary .. " \226\128\148 " .. text) or text
  end
  -- The count is a control only while there is one to click; otherwise the
  -- title bar drags from under it like anywhere else.
  local frame = UI._frame
  local hover = frame and frame.StatusHover
  if hover and hover.SetMouseClickEnabled then hover:SetMouseClickEnabled(stuck > 0) end

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

-- Width's floor is a chosen number, and the default width is that minimum:
-- everything on both tabs fits it and measures itself to it. The one exception
-- is an edge case of the Mail tab's top row -- counts in the thousands beside a
-- long translation, a wide host font, another character's box with a long name
-- -- which can need more than 480 however its parts give way; for exactly as
-- long as that lasts the floor is raised to what the row needs (MinWindowWidth,
-- below). There is deliberately no minimum or default HEIGHT here: both are
-- computed below.
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

  -- The collect screen is told the compose screen's need and answers with a
  -- whole-row height that clears it, so the floor shows whole rows whichever
  -- screen set it.
  local collect = ns.CollectTab
  if collect and type(collect.MinPanelHeight) == "function" then
    panel = max(panel, tonumber((collect.MinPanelHeight(panel))) or 0)
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

-- THE WIDTH FLOOR: 480, or what the Mail tab's top row needs where that is
-- more (Core/CollectTab.lua, CT.MinPanelWidth -- the row with every part at
-- its narrowest), plus the shell's own margin either side of the panel. Never
-- past the ceiling.
--
-- TRANSIENT WIDTH is the width a raised floor LENDS the window (`extraW`),
-- the way the compose screen lends it height: the width the player chose is
-- the window's less it, it is what persists, and it is what the window goes
-- back to when the floor comes down. A drag or a reset on the grip makes the
-- window's width the player's own again (AdoptTransientHeight).
local function MinWindowWidth()
  local need = MIN_WIDTH
  local panel, collect = CollectPanel(), ns.CollectTab
  if panel and collect and type(collect.MinPanelWidth) == "function" then
    -- Parenthesised: the shell's inset is ChromeChain's first return.
    local width = tonumber((collect.MinPanelWidth(panel))) or 0
    if width > 0 then need = max(need, ceil(width + 2 * (ChromeChain()))) end
  end
  return min(need, MAX_WIDTH)
end

-- The ceiling, from the one place that owns it. MAX_HEIGHT is taste, so the
-- derived floor overrides it wherever the two would cross -- a window that
-- cannot be as tall as its own content needs is not a matter of taste.
--
-- Read by the resize grip's bounds AND by the message box's elastic extension:
-- the window must never end up at a height the user could not have dragged it
-- to, or the next grab of the grip would snap it back down to one.
-- WHOLE ROWS ABOVE THE FLOOR. The floor shows exactly its rows (see
-- CT.MinPanelHeight), and the list is the one band that grows, so a height
-- shows whole rows exactly when what stands above the floor is a multiple
-- of a row's pitch. This puts `height` on the nearest such step -- down,
-- unless `nearest` asks for the closest, which is what a live drag wants
-- so the window steps a row at a time under the cursor. `body` is the
-- message box's elastic extension, which rides above the rows and is left
-- exactly as it is.
local function SnapHeight(height, floorHeight, body, nearest)
  local collect = ns.CollectTab
  local stride = (collect and type(collect.RowStride) == "function")
    and tonumber((collect.RowStride())) or 0
  if stride <= 0 then return height end
  local above = height - (body or 0) - floorHeight
  if above <= 0 then return height end
  local steps = nearest and floor(above / stride + 0.5) or floor(above / stride + 0.001)
  return floorHeight + (body or 0) + steps * stride
end

-- The ceiling, on the same steps as everything else: the tallest whole-row
-- height at or under the taste limit, and never under the floor.
local function MaxWindowHeight()
  local floorHeight = MinWindowHeight(UI._state.attachRows)
  return SnapHeight(max(MAX_HEIGHT, floorHeight), floorHeight, 0, false)
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
  local minWidth = MinWindowWidth()
  -- Remembered, so an option that moves the floor can tell whether the
  -- window was standing on the old one (FollowFloor).
  UI._state.floorH = minHeight

  if type(frame.SetResizeBounds) == "function" then
    frame:SetResizeBounds(minWidth, minHeight, MAX_WIDTH, maxHeight)
  elseif type(frame.SetMinResize) == "function" then
    frame:SetMinResize(minWidth, minHeight)
    if type(frame.SetMaxResize) == "function" then
      frame:SetMaxResize(MAX_WIDTH, maxHeight)
    end
  end

  local width  = tonumber(frame:GetWidth()) or 0
  local height = tonumber(frame:GetHeight()) or 0
  -- The width the player chose, held to the chosen bounds, and the floor's
  -- loan on top of it where the floor stands higher: raised, the window
  -- grows to it; lowered, the loan is given back, down to their width.
  local chosen = max(MIN_WIDTH, min(MAX_WIDTH, width - UI._state.extraW))
  local clampedW = max(chosen, minWidth)
  UI._state.extraW = clampedW - chosen
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
--
-- The width a raised floor lent the window is adopted the same way: whatever
-- width the drag leaves is the player's, and stays when the floor comes down.
local function AdoptTransientHeight(frame)
  -- Remembered so a press that never becomes a drag can be undone on release:
  -- adopting on a bare click would otherwise fold the extension into the base
  -- and write it to the saved height (see the release callback in section 4).
  UI._state.adoptedBodyH = UI._state.bodyH
  UI._state.adoptedAtHeight = (frame and frame.GetHeight) and frame:GetHeight() or nil
  UI._state.bodyH = 0
  UI._state.adoptedExtraW = UI._state.extraW
  UI._state.adoptedAtWidth = (frame and frame.GetWidth) and frame:GetWidth() or nil
  UI._state.extraW = 0
  local send = ns.SendTab
  if send and send.SuspendElastic then send.SuspendElastic(true) end
end

-- Reset to defaults (UI.ResetSettings): the size and place a first open
-- uses. The stored ones are already cleared; this moves the window still
-- standing on them, which would otherwise write them straight back the next
-- time it hides. The message extension is folded away the way the grip does
-- it and the compose screen re-reads its baseline at the new size; an
-- attachment row keeps its height, being still on screen. Docked, the window
-- goes back into its slot.
function UI.ResetWindowGeometry()
  local frame = UI._frame
  if not frame then return end
  local state = UI._state
  AdoptTransientHeight(frame)
  state.adoptedBodyH, state.adoptedAtHeight = nil, nil
  state.adoptedExtraW, state.adoptedAtWidth = nil, nil
  state.freeMoved = false

  -- Where BuildFrame first puts it.
  frame:ClearAllPoints()
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 50)
  local helpers = WindowHelpers()
  if helpers and helpers.PinFrameTopLeft then helpers.PinFrameTopLeft(frame) end
  frame:SetSize(DEFAULT_WIDTH, BaseMinHeight() + state.extraH)
  ApplyResizeBounds()
  UI.ApplyWindowLayout()

  local send = ns.SendTab
  if send and send.SuspendElastic then send.SuspendElastic(false) end
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
      -- The lightest possible "you've got mail": one dot, gone the moment
      -- nothing is left to collect -- and it carries the STATE, not just
      -- the fact. Orange when the server refused something (the same orange
      -- the row marker and the status line wear), otherwise the live accent
      -- -- under a host skin the user's own colour is the accent.
      if toCollect > 0 and theme then
        local r, g, b
        local mailApi = ns.MailService
        local stuck = (mailApi and type(mailApi.StuckCount) == "function"
          and mailApi.StuckCount()) or 0
        if stuck > 0 and theme.Colors and theme.Colors.warning then
          local warn = theme.Colors.warning
          r, g, b = warn[1], warn[2], warn[3]
        elseif theme.GetAccent then
          r, g, b = theme.GetAccent()
        end
        if r then
          suffix = ("|cff%02x%02x%02x\226\128\162|r"):format(
            math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
            math.floor(b * 255 + 0.5))
        end
      end
    elseif toCollect > 0 then
      suffix = "(" .. toCollect .. ")"
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

-- What the shell does about an inbox update, once per frame however many
-- updates arrive in it. MAIL_INBOX_UPDATE comes in bursts -- the initial load,
-- every body fetch, every CheckInbox -- and each of the three steps below can
-- walk the whole inbox: the stuck prune, the stuck count behind the status
-- line (both whenever anything has been refused), and the tab caption's counts
-- (with the collect panel hidden, the one case that caption is FOR, nothing
-- else has walked). Run per event, a burst of N paid N walks of each; run
-- here, it pays one, a frame later, the same pattern as the list's own refresh.
local inboxPassQueued = false

local function InboxPass()
  inboxPassQueued = false
  -- Timed with the rest of an open's work (Postbox.lua, 5b).
  local perf = ns.Perf
  local perfAt = perf and perf.cur and type(perf.Begin) == "function" and perf.Begin() or nil

  -- Refusals whose mail has gone are forgotten first, where the whole inbox
  -- can be seen (the service decides whether it can): before the summary
  -- below counts them.
  local service = ns.MailService
  if service and type(service.PruneStuck) == "function" then
    service.PruneStuck(UI._state.inboxSeen)
  end
  -- Safe unconditionally: this only recomputes the idle summary, which is the
  -- lowest-priority layer and can never displace a run's status.
  UI.UpdateStatusSummary()
  -- The tab caption's numbers moved with the inbox.
  UpdateCollectTabText()

  if perfAt then perf.End("summary", perfAt) end
end

local function QueueInboxPass()
  if inboxPassQueued then return end
  inboxPassQueued = true
  local ok = pcall(C_Timer.After, 0, InboxPass)
  -- The flag is a latch; a pass that could not be scheduled runs now instead.
  if not ok then InboxPass() end
end

-- The Mail tab's half of right-click-to-attach, in one place because two
-- callers need the same decision: the tab switch below, and the option itself
-- being changed with the mailbox already open.
--
-- The two branches are not symmetrical, and deliberately so. Arming is the
-- flag alone -- the compose screen's padlock overlays do not belong on the
-- Mail tab -- so the overlays are cleared separately. Disarming is one call
-- that drops the flag AND clears the overlays, which is a single container
-- repaint rather than two.
local function ApplyMailTabAttach()
  local send = ns.SendTab
  if not send then return end

  if UI.GetOption("attachFromMail") then
    if send.ArmNativeSendMail then send.ArmNativeSendMail() end
    if send.ClearBagOverlays then send.ClearBagOverlays() end
  elseif send.DeactivateNativeSendMail then
    send.DeactivateNativeSendMail()
  end
end

function UI.SelectTab(tabId)
  if not TAB_LABEL_KEY[tabId] then return end

  -- A switch, timed on the visit's record (Postbox.lua, 5b) with everything
  -- it sets off: the panels' own show and hide, and the bags' repaints. The
  -- open's re-assertion of the same tab is part of the open's own stages.
  local perf = ns.Perf
  local perfAt = perf and perf.visit and UI._state.activeTab ~= tabId and perf.Mark() or nil

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
    -- Called AFTER the panel loop, because hiding the compose panel above ran
    -- its OnHide, which dropped the attach flag -- so an arming decision made
    -- before this point would be undone by it either way.
    ApplyMailTabAttach()
    -- The window's compose-only extra height belongs to the compose screen --
    -- both kinds of it. Dropping them here rather than trusting the screen to
    -- remember means the window can never be left tall on the collect tab,
    -- which has neither an attachment row nor a message box to justify it.
    -- (activeTab is already the new tab, so the message extension would refuse
    -- to grow again from here anyway; this is what gives back the standing one.)
    UI.SetMessageExtraHeight(0)
    UI.SetAttachmentRows(1)
  end

  if perfAt then perf.Done(tabId == "send" and "send" or "mail", perfAt) end
end

-------------------------------------------------------------
-- 5b. Quick attach
--
-- Off by default; the "Attach from the Mail tab" option is what arms any of
-- this (see OPTION_DEFAULTS.attachFromMail).
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
  -- The baseline is kept up to date whether the feature is on or not, so
  -- switching it on mid-session compares against what the draft holds NOW
  -- rather than against a number from before it was off.
  lastAttachmentCount = count

  if not grew or not UI._state.mailboxOpen then return end
  if UI._state.activeTab == "send" then return end
  -- With the option off the flag is not armed, so nothing SHOULD be able to
  -- grow the draft from here. Stated rather than inferred: whether the
  -- feature is on is a question this file can answer, and the alternative is
  -- reading a flag two files away to find out.
  if not UI.GetOption("attachFromMail") then return end
  UI.SelectTab("send")
end

-- Frozen: Core/OptionsPanel.lua calls this when the attach option changes.
-- A setting that only took effect at the next mailbox visit would look broken
-- to someone who switched it on while standing at one.
function UI.RefreshMailTabAttach()
  if not UI._state.mailboxOpen then return end
  -- The Send tab arms the flag on its own account and this option cannot
  -- reach it; re-deciding here would disarm the tab the player is looking at.
  if UI._state.activeTab == "send" then return end
  ApplyMailTabAttach()
end

-- Frozen: Core/OptionsPanel.lua calls this when the tab-count option changes.
function UI.RefreshCollectTabCounts()
  local panel, collect = CollectPanel(), ns.CollectTab
  if panel and collect and collect.UpdateTabCounts then
    collect.UpdateTabCounts(panel)
  end
  -- The category buttons carry the same switch's counts.
  if panel and collect and collect.RefreshCategoryButtons then
    collect.RefreshCategoryButtons(panel)
  end
  UpdateCollectTabText()
end

-- Frozen: Core/OptionsPanel.lua calls this when the category-buttons option
-- changes. Synchronous, like the two around it.
-- An option moved the window's floor. A window STANDING on the old floor --
-- which is where a window that has never been resized stands, and where the
-- list shows exactly its whole rows -- goes with it, up or down, and the
-- height is saved so the next open agrees. A window the player dragged
-- taller keeps its height; the bounds alone lift it if the floor rose past
-- it. The old floor is the one ApplyResizeBounds last recorded, BEFORE the
-- option flipped -- comparing floors computed after the flip finds them
-- equal, which is the bug the first attempt at this had.
local function FollowFloor()
  local frame = UI._frame
  if not frame then return end
  local before = UI._state.floorH
  local after = MinWindowHeight(UI._state.attachRows)
  if before and after ~= before then
    local height = tonumber(frame:GetHeight()) or 0
    local standing = height - (UI._state.bodyH or 0)
    if standing - before < 0.5 and before - standing < 0.5 then
      local helpers = WindowHelpers()
      if helpers and helpers.PinFrameTopLeft then helpers.PinFrameTopLeft(frame) end
      frame:SetHeight(height + (after - before))
      if helpers and helpers.SaveFramePosition and UI._windowStore then
        helpers.SaveFramePosition(frame, UI._windowStore)
      end
    end
  end
  ApplyResizeBounds()
  UI.ApplyWindowLayout()
end

function UI.RefreshCollectCategoryButtons()
  local panel, collect = CollectPanel(), ns.CollectTab
  if not (panel and collect and collect.RefreshCategoryButtons) then return end
  collect.RefreshCategoryButtons(panel)
  FollowFloor()
end

-- The category grid grew or lost a row of buttons without an option moving
-- -- a button hidden or shown in the arrange mode, a character group's
-- button come or gone -- and the window's floor moves with it, exactly as
-- it does for the option above. Called by the grid itself (CollectTab, "The
-- category grid"), which remembers the rows the floor was last taken at, so
-- this runs only when that number changes.
function UI.RefreshCollectFloor()
  FollowFloor()
end

-- The Mail tab's top row needs a different width (CT.MinPanelWidth): another
-- character's box came or went, a count gained or lost a digit, the fonts
-- changed. Called by the row only when that number moves. The floor follows
-- it, and the window with it -- grown to a raised floor, and given back to the
-- player's own width as the floor comes down (MinWindowWidth). Docked, the
-- panel slot is re-reserved at the new width.
function UI.RefreshCollectWidth()
  local frame = UI._frame
  -- Not while the screens are still being built: the build's own bounds pass
  -- comes after the saved size is restored.
  if not (frame and CollectPanel()) then return end
  local before = frame:GetWidth()
  ApplyResizeBounds()
  if frame:GetWidth() ~= before then UI.ApplyWindowLayout() end
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
  -- The floor moved with the row pitch.
  FollowFloor()
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
  -- Two different title bars, two different centres: a HOST skin rebuilds
  -- the bar and -4 sits level with its title text, while the stock template
  -- keeps its own TitleText higher and -4 reads a couple of pixels low
  -- beside it.
  --
  -- The test is the host UI, not ns.Skin: Postbox Modern claims ns.Skin too
  -- but repaints the template's OWN bar rather than rebuilding one, so it
  -- belongs with the stock case -- reading ns.Skin alone dropped Modern's
  -- cog two pixels. Host globals are settled at login, well before a
  -- mailbox can build this frame.
  local hostBar = (ns.Skin and (_G.EllesmereUI or _G.ElvUI)) and true or false
  button:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, hostBar and -4 or -2)
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
    -- The gesture, in the grey the arrange mark's is: the title already
    -- says what opens.
    GameTooltip:AddLine(L("OPTIONS_COG_TOOLTIP"), 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function()
    if GameTooltip then GameTooltip:Hide() end
  end)

  return button
end

-- The cog key, right of the cog and anchored TO it by its left edge, so it
-- stands level with the cog in every look -- the skins move the cog, and it
-- follows -- and widens to the right into Done while the mode is open. It
-- arranges the Mail tab's rows and buttons, bringing that tab forward from
-- the Send tab first (Core/Arrange.lua). Nothing at all without that file:
-- it is new in 1.50, and a /reload does not load a new file.
local function BuildArrangeButton(frame)
  local arrange = ns.Arrange
  if not (arrange and arrange.BuildToggle and frame.OptionsButton) then return nil end
  return arrange.BuildToggle(frame, function(button)
    button:SetPoint("LEFT", frame.OptionsButton, "RIGHT", 4, 0)
  end, function()
    if UI._state.activeTab ~= "collect" then UI.SelectTab("collect") end
    local panel, collect = CollectPanel(), ns.CollectTab
    if not (panel and collect and collect.ArrangeHost) then return nil end
    return collect.ArrangeHost(panel)
  end)
end

-- Every way into Mail Memory, while a mailbox is open (Core/MailMemory.lua's
-- Toggle): this window's Mail tab already shows the other characters, so it
-- comes forward with the character list open under its button.
-- Frozen: Core/OptionsPanel.lua calls this when Mail Memory is switched on
-- or off. The Mail tab's picker and search toggle come and go with it, and
-- the memory's own window closes when there is no memory to show.
function UI.RefreshMemoryState()
  local panel, collect = CollectPanel(), ns.CollectTab
  if panel and collect and collect.RefreshOthers then collect.RefreshOthers(panel) end
  local memory = ns.MailMemory
  if memory and memory._frame and not UI.GetOption("mailMemory") then memory._frame:Hide() end
end

function UI.ShowCharacterPicker()
  local frame = UI._frame
  if not (frame and frame:IsShown()) then return end
  if UI._state.activeTab ~= "collect" then UI.SelectTab("collect") end
  local panel, collect = CollectPanel(), ns.CollectTab
  if not (panel and collect and collect.OpenPicker) then return end
  -- A frame later: the tab has only just been laid out, and the list hangs
  -- from its button.
  C_Timer.After(0, function() collect.OpenPicker(panel) end)
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
  -- Published for the one write outside this function: a floor change
  -- (RefreshCollectCategoryButtons) that moves the window has to save the
  -- height it moved to, or the next open clamps back to the old one.
  UI._windowStore = windowStore

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

    -- Motion only, and NEVER EnableMouse: this frame lies across the right
    -- half of the title bar, and the window is dragged from the title bar.
    -- `EnableMouse(true)` turns on clicks AND motion, and following it with
    -- SetMouseClickEnabled(false) does not reliably give the mouse-down
    -- back to the parent -- so the one strip of title bar this frame covers
    -- was the one strip the window could not be dragged by. The granular
    -- setters alone leave the click path untouched from the start.
    --
    -- Guarded, and with a propagation fallback: both setters are modern
    -- additions, and a client with neither must end up with a frame that
    -- takes no mouse at all rather than one that eats drags.
    if statusHover.SetMouseMotionEnabled and statusHover.SetMouseClickEnabled then
      statusHover:SetMouseClickEnabled(false)
      statusHover:SetMouseMotionEnabled(true)
      if statusHover.SetPropagateMouseClicks then
        statusHover:SetPropagateMouseClicks(true)
      end
    else
      statusHover:EnableMouse(false)
    end
    statusHover:SetScript("OnEnter", function(self)
      local label = frame.Status
      local text = label and label:GetText() or ""
      if text == "" then return end

      -- Three things worth a tooltip: a truncated line (the full text), full
      -- bags (what waits for room, and what brings it back), and a stuck
      -- count (WHICH mails, one line each, in the same words the row
      -- tooltips use). The details come from the registry's validated read,
      -- so this list and the row triangles can never disagree.
      local mail = ns.MailService
      local details = mail and type(mail.StuckDetails) == "function"
        and mail.StuckDetails() or nil
      local full = mail and type(mail.BagsFull) == "function" and mail.BagsFull()
      local truncated = label.IsTruncated and label:IsTruncated()
      if not details and not full and not truncated then return end

      GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
      GameTooltip:SetText(text, 1, 1, 1, 1, true)
      if full then
        GameTooltip:AddLine(L("BAGS_FULL_TIP"), 0.75, 0.75, 0.75, true)
      end
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
        local collect = ns.CollectTab
        local on = collect and collect.StuckFilterOn and collect.StuckFilterOn(CollectPanel())
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L(on and "STUCK_FILTER_OFF_TIP" or "STUCK_FILTER_ON_TIP"), 0.6, 0.6, 0.6, true)
      end
      GameTooltip:Show()
    end)
    statusHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- A click on "Stuck: N" narrows the inbox to those mails, and back. The
    -- press also reaches the title bar, which drags the window from it: a
    -- press that moved is a drag, and a drag is not a click.
    statusHover:SetScript("OnMouseDown", function(self)
      self._downX, self._downY = GetCursorPosition()
    end)
    statusHover:SetScript("OnMouseUp", function(self, button)
      if button ~= "LeftButton" then return end
      local x, y = GetCursorPosition()
      local dx, dy = (x or 0) - (self._downX or x or 0), (y or 0) - (self._downY or y or 0)
      self._downX, self._downY = nil, nil
      if dx * dx + dy * dy > 16 then return end
      local mail = ns.MailService
      local stuck = mail and type(mail.StuckCount) == "function" and mail.StuckCount() or 0
      if stuck == 0 then return end
      local collect = ns.CollectTab
      if not (collect and collect.ToggleStuckFilter) then return end
      -- From the Send tab the click means "show me them": the Mail tab comes
      -- forward with the filter on, never off where nobody can see it.
      if UI._state.activeTab ~= "collect" then
        UI.SelectTab("collect")
        collect.ToggleStuckFilter(CollectPanel(), true)
        return
      end
      collect.ToggleStuckFilter(CollectPanel())
    end)
    frame.StatusHover = statusHover
  end

  frame.OptionsButton = BuildOptionsButton(frame, theme)
  frame.ArrangeButton = BuildArrangeButton(frame)

  -- Resize grip. The foundation layer debounces the size write, so a drag does
  -- not write saved variables sixty times a second; the stop callback only runs
  -- on release. The start callback is what makes the GRIP WIN over the message
  -- box's elastic extension: see AdoptTransientHeight.
  if helpers and helpers.CreateResizeButton then
    local function OnResizeStop(resized)
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
      -- The same for the width a raised floor lent: a drag that left the
      -- width as it was leaves it on loan, and it still goes back.
      local w = (resized and resized.GetWidth) and resized:GetWidth() or nil
      if st.adoptedAtWidth ~= nil and w ~= nil
          and w - st.adoptedAtWidth < 0.5 and st.adoptedAtWidth - w < 0.5 then
        st.extraW = st.adoptedExtraW or 0
      end
      st.adoptedExtraW, st.adoptedAtWidth = nil, nil
      -- The drag was held to the floor as it stood at the press; one raised
      -- since (a count gaining a digit mid-drag) is met now.
      if w ~= nil and w < MinWindowWidth() then ApplyResizeBounds() end
      if helpers.SaveFramePosition then helpers.SaveFramePosition(resized, windowStore) end
      UI.ApplyWindowLayout()
      -- Last, and after the re-dock: the compose screen re-reads its baseline
      -- from the size the user settled on, at the position it settled at.
      local send = ns.SendTab
      if send and send.SuspendElastic then send.SuspendElastic(false, bareClick) end
    end

    -- Right-click on the grip: the size the window opens at for a player who
    -- has never touched it -- the default width and the derived floor, which
    -- is the smallest size the screens fit in -- through the same release
    -- path a drag takes, so it is saved, re-docked and re-read the same way.
    -- Where the Mail tab's top row has raised the width's floor, the window
    -- stands on that instead, on loan, and comes back to the default width
    -- when the floor does.
    local function OnResizeReset(target)
      AdoptTransientHeight(target)
      helpers.PinFrameTopLeft(target)
      local width = max(DEFAULT_WIDTH, MinWindowWidth())
      target:SetSize(width, BaseMinHeight())
      UI._state.extraW = width - DEFAULT_WIDTH
      UI._state.adoptedAtWidth = nil
      OnResizeStop(target)
    end

    -- The drag is free between the bounds. It stepped a row at a time for a
    -- while, so the window never stopped on part of one -- and it felt like
    -- a window that would not do what the hand asked. The floor and the
    -- ceiling are whole rows; between them the height is the player's.
    local function OnResizeSnap(_, height)
      return height
    end

    frame.ResizeButton = helpers.CreateResizeButton(frame, OnResizeStop,
      AdoptTransientHeight, DragMinHeight, OnResizeReset, OnResizeSnap)
    -- The right-click cannot be discovered by looking: a small hint of the
    -- theme's own says both gestures, one to a line, quieter than a full
    -- tooltip. Built once, not on every hover.
    local grip = frame.ResizeButton
    if grip and ns.Theme and ns.Theme.ShowHint then
      local gripHint = { L("GRIP_TIP_DRAG"), L("GRIP_TIP_RESET") }
      grip:HookScript("OnEnter", function(self)
        ns.Theme.ShowHint(self, gripHint)
      end)
      grip:HookScript("OnLeave", function() ns.Theme.HideHint() end)
      -- Gone the moment the grip is pressed: a drag moves the window from
      -- under it, and it has said what it had to.
      grip:HookScript("OnMouseDown", function() ns.Theme.HideHint() end)
    end
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
      -- And the width a raised floor lent, so what is saved is the player's.
      extraWidthFn = function() return UI._state.extraW end,
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

-- `reason` is "open" or "close": the compose screen keeps an unsent draft
-- across the gap between the two, and it needs to know which side of it this
-- is. The collect screen's search is cleared on the same close.
local function ResetDraft(reason)
  local panel, send = SendPanel(), ns.SendTab
  if panel and send and send.Reset then send.Reset(panel, reason) end
  if reason == "close" then
    local collectPanel, collect = CollectPanel(), ns.CollectTab
    if collectPanel and collect and collect.ClearSearch then collect.ClearSearch(collectPanel) end
  end
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

  -- /postbox debug's record of this open (Postbox.lua, 5b): each stage's time,
  -- then what the next half minute of inbox updates costs. `mark` is nil when
  -- the record is unavailable, and every Stage call below is skipped with it.
  local perf = ns.Perf
  local mark = perf and type(perf.Open) == "function" and perf.Open() or nil

  UI._state.mailboxOpen = true
  -- The inbox always reads empty between MAIL_SHOW and the first
  -- MAIL_INBOX_UPDATE; anything that would treat "empty" as a fact about the
  -- mailbox must wait until this flips (see UpdateStatusSummary's erasure).
  UI._state.inboxSeen = false
  SyncQuickAttachBaseline()
  BuildFrame()
  if mark then mark = perf.Stage("build", mark) end

  UI.ClearStatus()
  ResetDraft("open")
  if mark then mark = perf.Stage("draft", mark) end
  -- Re-assert the active tab on every open so the native send-mail state is
  -- re-armed; BuildFrame only selects a tab on the very first open.
  UI.SelectTab(UI._state.activeTab)
  UI.Show(true)
  -- Showing the window runs its OnShow hooks: the skin's refresh pass and the
  -- visible panel's own OnShow, which for the collect screen is a list refresh.
  if mark then mark = perf.Stage("select", mark) end
  -- Before the list refresh: the revived registry is what paints the row
  -- triangles on the very first build after a relog.
  local collectTab = ns.CollectTab
  if collectTab and type(collectTab.SeedStuckFromRecord) == "function" then
    collectTab.SeedStuckFromRecord()
  end
  if mark then mark = perf.Stage("seed", mark) end
  RefreshCollectPanel()
  UI.UpdateStatusSummary()
  -- After the refresh, which records the inbox counts this reads.
  UpdateCollectTabText()
  if mark then mark = perf.Stage("refresh", mark) end
  -- Dock last, now that both our window and the invisible MailFrame are shown
  -- and positioned.
  UI.ApplyWindowLayout()
  if mark then perf.Stage("layout", mark, true) end
end

-- The mail session ended. MAIL_CLOSED and the interaction manager's hide event
-- both fire for one close, so this is idempotent.
local function OnMailClosed()
  -- The open's measuring window ends with the session (Postbox.lua, 5b). First,
  -- while the inbox can still be read, and a no-op on the second close signal.
  -- The close itself is timed too, in parts, on the same open's record: it
  -- began with Mail Memory's save if that ran first, and ends below.
  local perf = ns.Perf
  if perf and type(perf.CloseBegin) == "function" then perf.CloseBegin() end
  if perf and type(perf.Settle) == "function" then perf.Settle("closed") end

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
    local draftAt = perf and perf.visit and perf.Mark()
    ResetDraft("close")
    if draftAt then perf.ClosePart("draft", draftAt) end
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

  -- Hiding the window runs every panel's OnHide, the compose screen's bag
  -- clearing among them when that screen was up.
  local hideAt = perf and perf.visit and perf.Mark()
  if UI._frame then UI._frame:Hide() end
  if hideAt then perf.ClosePart("hide", hideAt) end
  UI._state.visible = false
  UI.ClearStatus()
  if perf and type(perf.CloseEnd) == "function" then perf.CloseEnd() end

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
-- 9. Diagnostics
--
-- Two lines for the bug report (Postbox.lua section 6). Both are built from
-- live state rather than from a list kept alongside it: the settings line
-- walks OPTION_DEFAULTS, so a switch added in six months' time appears in
-- every report from the day it ships without anyone remembering this
-- function exists. (A setting that is a word or a number has to be named in
-- it, below.) A report that quietly stops covering a setting is worse than
-- no report, because it reads as a setting that was checked.
-------------------------------------------------------------

-- Every profile option, with a "*" against any value the player has moved
-- off its default -- so a report full of defaults can be dismissed at a
-- glance and the two settings someone actually changed stand out.
function UI.DiagnoseOptions()
  local keys = {}
  for key in pairs(OPTION_DEFAULTS) do keys[#keys + 1] = key end
  -- Sorted, so two reports of the same bug are diffable.
  table.sort(keys)

  local parts = {}
  for i = 1, #keys do
    local key = keys[i]
    local on = UI.GetOption(key)
    parts[i] = string.format("%s=%s%s", key, on and "on" or "off",
      (on ~= (OPTION_DEFAULTS[key] == true)) and "*" or "")
  end
  -- The settings that are a word or a number are not in OPTION_DEFAULTS, so
  -- each is named here: the value its accessor answers with -- the one in
  -- force, whatever is stored -- and the same "*" off its default.
  local function Named(key, value, default)
    value = tostring(value)
    parts[#parts + 1] = string.format("%s=%s%s", key, value, (value ~= default) and "*" or "")
  end
  Named("style", (UI.GetStyleChoice()), HostInstalled() and "host" or "blizzard")
  -- EllesmereUI's own look, and the skin standing down, where its skin says.
  local eui = ns.SkinEllesmere
  if eui and type(eui.Diagnose) == "function" then
    local ok, report = pcall(eui.Diagnose)
    if ok and type(report) == "table" then
      if report.look then parts[#parts + 1] = "look=" .. tostring(report.look) end
      if report.standDown then parts[#parts + 1] = "standdown=" .. tostring(report.standDown) end
    end
  end
  Named("qualityIcon", UI.GetQualityIcon() and "on" or "off", "on")
  Named("qualityName", UI.GetQualityName(), "off")
  Named("readMail", UI.GetReadMode(), "fold")
  Named("historyDays", UI.GetHistoryDays(), "7")
  Named("afterSend", UI.GetAfterSendKeep(), "nothing")
  -- Each arrangement's own choices: the one-line rows' under the names
  -- they had while they were everyone's.
  Named("gold", UI.GetGoldMode("rows"), "both")
  Named("expiry", UI.GetExpiryWhen("rows"), "always")
  Named("slots", UI.GetSlotsStyle(), "words")
  Named("largeGold", UI.GetGoldMode("large"), "both")
  Named("largeExpiry", UI.GetExpiryWhen("large"), "always")
  Named("historyGold", UI.GetGoldMode("history"), "both")
  Named("rows", FormatRowLayout(UI.GetRowLayout()) or "?", ROW_LAYOUT_DEFAULT)
  Named("largeRows", FormatRowLayout(UI.GetLargeLayout()) or "?", ROW_LAYOUT_DEFAULT)
  Named("historyRows", FormatLayout(UI.GetHistoryLayout(), ParseHistoryLayout) or "?", HISTORY_LAYOUT_DEFAULT)
  Named("historyAge", UI.GetHistoryAge(), "short")
  do
    local other = ns.Store and ns.Store.Get and ns.Store.Get("profile.historyAgeOther")
    if other ~= nil then Named("historyAgeOther", other, "") end
  end
  -- The grid as stored: its group buttons are ids ("group:3"), never names.
  local grid = ns.Store and ns.Store.Get and ns.Store.Get("profile.gridLayout")
  Named("grid", (type(grid) == "string" and grid ~= "") and grid or "default", "default")
  local icon = ns.MinimapButton
  if icon and type(icon.GetEnabled) == "function" then
    Named("minimap", icon.GetEnabled() and "on" or "off", "off")
  end
  return table.concat(parts, " ")
end

-- Where the window is and what it is doing. Reported even with no window
-- built, because "the mailbox never opened" is itself a bug report.
function UI.Diagnose()
  local state = UI._state
  local frame = UI._frame

  local geometry = "no window yet"
  if frame then
    -- pcall'd, and GetPoint is the reason: on a frame with no anchor points
    -- it is not a dependable nil -- some clients raise instead -- and there
    -- is one moment, between construction and the first layout, when that is
    -- exactly the frame's state. A bug report must not be the second thing
    -- to break.
    local ok, text = pcall(function()
      -- Rounded: a fractional pixel here is UI scale, not information, and
      -- the scale is already on the report's second line.
      local point, _, _, x, y = frame:GetPoint()
      return string.format("%dx%d at %s %d,%d",
        math.floor(frame:GetWidth() + 0.5), math.floor(frame:GetHeight() + 0.5),
        tostring(point), math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5))
    end)
    geometry = ok and text or "window built, geometry unreadable"
  end

  -- The inbox size is the difference between "Postbox showed me nothing" and
  -- "there was nothing to show", and only the client can settle it.
  local inbox = "?"
  if type(GetInboxNumItems) == "function" then
    local ok, shown, total = pcall(GetInboxNumItems)
    if ok then inbox = string.format("%s/%s", tostring(shown), tostring(total)) end
  end

  -- The native frame's own state, because "both windows are open" is the one
  -- report this addon cannot see from its own side. Alpha and shown, and --
  -- when the alpha hook in section 2 has had to act -- how often and who.
  local native = "native ?"
  if MailFrame and type(MailFrame.GetAlpha) == "function" then
    local ok, alpha, shown = pcall(function()
      return MailFrame:GetAlpha(), MailFrame:IsShown()
    end)
    if ok then
      native = string.format("native %s alpha %.2f", shown and "shown" or "hidden", alpha or 0)
    end
  end
  if (state.alphaFights or 0) > 0 then
    native = string.format("%s | alpha restored %dx after %s", native,
      state.alphaFights, tostring(state.alphaCulprit))
  end

  return string.format(
    "mailbox %s | window %s | tab %s | inbox %s | free-moved %s | layout deferred %s | %s | %s",
    state.mailboxOpen and "open" or "closed",
    state.visible and "shown" or "hidden",
    tostring(state.activeTab),
    inbox,
    tostring(state.freeMoved), tostring(state.layoutDeferred),
    geometry, native)
end

-------------------------------------------------------------
-- 10. Event plumbing
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
    -- Counted, with this handler's own time, while an open's record is
    -- measuring (Postbox.lua, 5b); nil otherwise.
    local perf = ns.Perf
    local perfAt = perf and perf.cur and type(perf.InboxEvent) == "function" and perf.InboxEvent() or nil

    -- Only two flags are set here, per event; everything that reads the inbox
    -- waits for the next frame, once, however many events arrive in this one.

    -- The inbox moved, so what the collect screen last counted is no longer
    -- true. Said now, before anything can read it: the refresh recounts and
    -- records as it rebuilds, but it is coalesced to the next frame AND skipped
    -- entirely while its panel is hidden -- so the caption, which shows on
    -- every tab, would otherwise be reporting the last visit's numbers.
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
    -- The stuck prune, the status summary and the tab caption (InboxPass,
    -- section 5): after the list refresh queued above, so its recorded counts
    -- are what the caption reads. The refresh re-renders the summary itself,
    -- and reads the registry through the same live-inbox filter the prune
    -- applies, so a refresh that runs first shows nothing the prune would
    -- have taken away.
    QueueInboxPass()

    if perfAt then perf.End("sync", perfAt) end
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
