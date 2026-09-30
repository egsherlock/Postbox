local ADDON_NAME, ns = ...

-- Postbox :: the entry point.
--
-- Everything here happens because it has to happen before anything else can:
-- the addon's identity, the two foundation bindings that give the rest of the
-- tree a saved-variables root and a chat printer, the shape of the saved
-- variables themselves, the running census of the player's own characters, the
-- error trap that has to be in place before there is anything to catch, the
-- timing record the bug report carries, the slash command, and the event bus
-- every other module registers on.
--
-- Two ordering rules govern this file, and both are easy to break by moving a
-- line a few rows up:
--
--   * Downwards, inside the file. Store.Bind is what tells the store which
--     global is ours, so no EnsurePath anywhere in the addon may run before it;
--     Logger.Bind creates ns.Print, and the event bus is handed that function
--     BY VALUE, so binding after the bus would leave the bus logging nowhere.
--   * Outwards, across the TOC. Postbox.lua loads after Lib\ and Core\Locales
--     and before the rest of Core\, so ns.Core.* and ns.L are available while
--     ns.Recipients, ns.MailboxUI, ns.RecipientManager and ns.SkinEllesmere are
--     not. Every reference to those is resolved at call time and type-guarded.
--     None of them may be captured into a local at file scope.

-------------------------------------------------------------
-- 1. Identity
-------------------------------------------------------------

ns.ADDON_NAME = ADDON_NAME

-- The TOC carries "@project-version@" as a substitution token that only the
-- release packager fills in. Anyone running the addon straight out of the
-- repository therefore gets the token itself, which would be shown to players
-- and pasted into bug reports as though it were a version number. Treat every
-- unsubstituted or unusable value as the honest answer instead.
local function CurrentVersion()
  local metadata = C_AddOns and C_AddOns.GetAddOnMetadata
  local value = metadata and metadata(ADDON_NAME, "Version")
  if type(value) ~= "string" or value == "" or value:sub(1, 1) == "@" then
    return "dev"
  end
  return value
end

ns.VERSION = CurrentVersion()

-------------------------------------------------------------
-- 2. Foundation bindings
--
-- PostboxDB is declared by the TOC and restored by the client just before
-- ADDON_LOADED, so there is deliberately no assignment to it here: the store
-- creates the table lazily on the first EnsurePath and adopts whatever the
-- client restored if that came first.
-------------------------------------------------------------

ns.Core.Store.Bind(ns, "PostboxDB")
ns.Core.Logger.Bind(ns, "Postbox", "d3a44a")

-------------------------------------------------------------
-- 3. Saved-variable schema
--
-- Every path an existing installation may already contain. Ensuring them all up
-- front means no reader further down the tree has to invent a missing table,
-- and the list doubles as the one place the layout is written out.
--
-- Two of these look like they belong under `profile` and deliberately do not:
-- MailboxUI's GetOption/SetOption coerce every profile value to a boolean, so a
-- profile key cannot carry a table. Recipient curation state and alt metadata
-- live at the root for that reason alone.
--
-- Realm keys throughout are the RAW GetRealmName() -- spaces, apostrophes and
-- all. Core/ContactService.lua and Core/Recipients.lua both index with exactly
-- that, so alts, altClasses and altMeta line up character for character.
--
-- The options' Reset everything (Core/MailboxUI.lua) empties every root here
-- but the census of the player's characters -- alts, altClasses, altMeta. A
-- new root is cleared by it too, unless it is added to CENSUS_KEEP there.
-------------------------------------------------------------

local PROFILE = "profile"

local SCHEMA = {
  PROFILE,                    -- account-wide settings, which Reset to defaults
                              -- clears: switches (MailboxUI.GetOption), and
                              -- words and numbers, each with an accessor pair
                              -- of its own in Core/MailboxUI.lua
  PROFILE .. ".recipientHistory",
  PROFILE .. ".minimap",      -- minimap mail icon; a table, so its module owns
                              -- it directly (see the note above on booleans)
  "alts",                     -- realm -> array of character names
  "altClasses",               -- realm -> name -> class token
  "recipients",               -- recipient key -> curation state
  "altMeta",                  -- realm -> name -> { level, faction, lastSeen }
  "charGroups",               -- the player's character groups (Core/CharacterGroups.lua)
  "lastRun",                  -- realm -> name -> last bad collect run
                              -- (see Core/CollectTab.lua, run memory)
  "mailMemory",               -- realm -> name -> last-seen inbox snapshot
                              -- (see Core/MailMemory.lua)
  "mailWatch",                -- realm -> name -> mail known to be on the way
                              -- since the last visit (Core/MailMemory.lua, 2b)
  "mailHistory",              -- realm -> name -> a week of what was collected
                              -- (Core/MailMemory.lua, 2c)
  "hiddenChars",              -- realm -> name -> true: hidden from the lists
                              -- of other characters (Core/MailMemory.lua, 2b)
}

local function EnsureDB()
  for i = 1, #SCHEMA do
    ns.Store.EnsurePath(SCHEMA[i])
  end
  return ns.Store.EnsurePath(PROFILE)
end

-------------------------------------------------------------
-- 4. Census of the player's own characters
--
-- Nothing in the API will tell one character about another, so the roster is
-- built the only way it can be: each character writes itself down as it logs
-- in, into an account-wide table the others can read. That is why an alt only
-- becomes mailable once it has been played with Postbox installed.
-------------------------------------------------------------

-- The roster is an array rather than a set because it is presented in the order
-- the characters were first seen, which is stable and means something to the
-- player. Duplicates are prevented by scanning it; these lists are one entry per
-- character per realm, so the scan is not worth trading for a second index.
local function RememberName(realm, name)
  local byRealm = ns.Store.EnsurePath("alts")
  local names = byRealm[realm]
  if type(names) ~= "table" then
    names = {}
    byRealm[realm] = names
  end

  for i = 1, #names do
    if names[i] == name then return end
  end
  names[#names + 1] = name
end

-- The class token is kept beside the name so contact lists can tint an alt in
-- its class colour. It has to be recorded here because it is unrecoverable
-- afterwards: once you are logged out of a character, nothing on the client
-- knows what class it was.
local function RememberClass(realm, name, classToken)
  if type(classToken) ~= "string" or classToken == "" then return end

  local byRealm = ns.Store.EnsurePath("altClasses")
  local classes = byRealm[realm]
  if type(classes) ~= "table" then
    classes = {}
    byRealm[realm] = classes
  end
  if classes[name] == classToken then return end
  classes[name] = classToken
  -- The mail rows colour this character's name from the census.
  local CS = ns.ContactService
  if CS and type(CS.ClassesChanged) == "function" then CS.ClassesChanged() end
end

-- Both of these return EXACTLY ONE value, deliberately: UnitFactionGroup also
-- hands back the localised name, and letting the second value through would
-- append a stray argument wherever the call sat last in a list -- the trap
-- Core/Helpers.lua documents at length.
local function CurrentLevel(levelOverride)
  if type(levelOverride) == "number" then return levelOverride end
  if type(UnitLevel) ~= "function" then return nil end
  return (UnitLevel("player"))
end

local function CurrentFaction()
  if type(UnitFactionGroup) ~= "function" then return nil end
  return (UnitFactionGroup("player"))
end

-- Level, faction and last-seen belong to the recipient manager, which owns its
-- own table and its own staleness rules. Best-effort by design: on a cold login
-- ADDON_LOADED can arrive before Core/Recipients.lua has run, and missing that
-- one write costs nothing -- PLAYER_LOGIN repeats it a moment later, by which
-- point the module certainly exists and UnitLevel is dependable.
local function ShareWithRecipients(name, realm, classToken, levelOverride)
  local Recipients = ns.Recipients
  if not (Recipients and type(Recipients.RecordAlt) == "function") then return end

  local level = CurrentLevel(levelOverride)
  local faction = CurrentFaction()
  Recipients.RecordAlt(name, realm, level, classToken, faction)
end

-- levelOverride: PLAYER_LEVEL_UP hands us the new level as its payload, and
-- UnitLevel("player") can still be reporting the old one at that instant.
local function RegisterCurrentAlt(levelOverride)
  EnsureDB()

  local name = UnitName("player")
  local realm = GetRealmName()
  -- Either half missing means a half-formed identity, and half a record is
  -- worse than none: it would be indistinguishable from a real character and
  -- would never be corrected.
  if type(name) ~= "string" or name == "" then return end
  if type(realm) ~= "string" or realm == "" then return end

  local _, classToken = UnitClass("player")

  RememberName(realm, name)
  RememberClass(realm, name, classToken)
  ShareWithRecipients(name, realm, classToken, levelOverride)
end

ns.EnsureDB = EnsureDB
ns.RegisterCurrentAlt = RegisterCurrentAlt

-------------------------------------------------------------
-- 4b. Which release saved them, and the steps that run once
--
-- `savedBy`, at the root: the version of the Postbox that last loaded these
-- saved variables, as the TOC gives it ("v1.50.0", "v1.50.0-beta.1", a dev
-- build's "v1.50.0-dev67"), written at every load from 1.50 on. An
-- unpackaged checkout's "dev" is not a version and is never written.
--
-- Before 1.50 nothing said so, and the saved variables' own shape does:
-- every 1.50 build makes the charGroups and hiddenChars roots at load
-- (SCHEMA, above), and no earlier release made either. Settings with neither
-- root beside them were last saved by 1.40.x or earlier, the 1.40.2 beta
-- included.
--
-- A release that has to do something once, for players coming to it from an
-- older one, adds a step to UPGRADES. A step runs at the first load that
-- finds saved variables older than its release, before any window is built
-- or any skin has claimed; the stamp written after it keeps it from running
-- again. Never on a first install: with nothing saved there is nothing to
-- carry over. And only on a build at least as new as the step's release (an
-- unpackaged checkout counts as the newest), so a build whose TOC names an
-- older version can never run a step and then stamp that older version,
-- which would run it again at every load.
-------------------------------------------------------------

local SAVED_BY = "savedBy"

-- A version as one number to compare, "v1.50.0-beta.1" -> 1050000; nil for
-- anything that is not a version.
local function ReleaseNumber(version)
  if type(version) ~= "string" then return nil end
  local major, minor, patch = version:match("^v?(%d+)%.(%d+)%.?(%d*)")
  if not major then return nil end
  return tonumber(major) * 1000000 + tonumber(minor) * 1000 + (tonumber(patch) or 0)
end

-- 1.50.0, the first release to make those two roots.
local RELEASE_150 = 1050000

-- The release that saved `db`, read before this load writes to it: the
-- stamp's; 1.50's for a 1.50 build's from before the stamp; 0 for an older
-- release's, which nothing names; nil for nothing to go on -- no saved
-- variables, a root that is not a table, or no settings in it.
local function SavedByRelease(db)
  if type(db) ~= "table" then return nil end
  local stamped = ReleaseNumber(db[SAVED_BY])
  if stamped then return stamped end
  if type(db.charGroups) == "table" or type(db.hiddenChars) == "table" then return RELEASE_150 end
  local profile = db.profile
  if type(profile) == "table" and next(profile) ~= nil then return 0 end
  return nil
end

-- 1.50.0: so many settings were renamed, moved or remade that a player
-- coming from 1.40 starts on 1.50's defaults, by the options' own Reset
-- settings (Core/MailboxUI.lua) and its keep list: recipients and recent
-- recipients, character groups, hidden characters, Mail Memory, History and
-- how long it keeps mail, whether the minimap icon is on, the characters.
-- Run after Postbox Modern's settings have been carried onto the Postbox
-- style (UI.Initialize), so a Modern player's reset lands on the Postbox
-- style as that reset always does. The mail window says so the first time
-- it opens, until the notice is answered (Core/WhatsNew.lua).
local function ResetForRelease150()
  local UI = ns.MailboxUI
  if not (UI and type(UI.ResetSettings) == "function") then return end
  UI.ResetSettings()
  PostboxDB.notice = "1.50"
end

local UPGRADES = {
  { before = RELEASE_150, run = ResetForRelease150 },
}

-- `savedBy`: SavedByRelease's answer for what the client restored. A step
-- that fails is reported and the rest go on; the stamp is written either
-- way, so a step can never repeat at every login.
local function Upgrade(savedBy)
  local own = ReleaseNumber(ns.VERSION)
  if savedBy then
    for i = 1, #UPGRADES do
      local step = UPGRADES[i]
      if savedBy < step.before and step.before <= (own or math.huge) then
        local ok, err = pcall(step.run)
        if not ok and type(geterrorhandler) == "function" then
          local handler = geterrorhandler()
          if type(handler) == "function" then handler(err) end
        end
      end
    end
  end
  if own and type(PostboxDB) == "table" then PostboxDB[SAVED_BY] = ns.VERSION end
end

-------------------------------------------------------------
-- 5. Error capture
--
-- A Lua error is announced once and then gone. By the time the player who
-- hit it gets round to writing the bug report, the single most useful thing
-- about it has scrolled out of the chat frame -- so what arrives instead is
-- "it broke", and the report is unactionable. The last few are kept here for
-- the diagnostic snapshot to carry.
--
-- Three rules govern this, and all three exist because the error handler is
-- shared with every other addon on the account:
--
--   * The previous handler is CHAINED, never replaced. Whatever was
--     installed before -- BugSack, an error-frame addon, Blizzard's own --
--     receives every error unchanged and in full, including ours.
--   * Only OUR errors are recorded. Another addon's stack trace is not ours
--     to collect and would not belong in a Postbox bug report.
--   * Nothing here runs until something has already gone wrong.
-------------------------------------------------------------

-- Five, not fifty: the first error is almost always the one that matters and
-- the rest are its wreckage, and this text is meant to be pasted into an
-- issue by hand.
local ERROR_LIMIT = 5
local errorLog = {}       -- newest last; {text, count, when}
local errorsSeen = 0      -- everything recorded this session, dropped ones too

-- An addon path in a message is spelled with backslashes on one client and
-- forward slashes on another, and the prefix is the same for every line --
-- so it is worth neither the width nor the reader's attention.
local function ShortenPath(text)
  text = text:gsub("[Ii]nterface[\\/][Aa]dd[Oo]ns[\\/]Postbox[\\/]", "")
  return text
end

-- A repeat is counted, not appended. One error inside an OnUpdate or a list
-- refresh fires every frame, and five identical lines would push out the
-- four different errors that came before it -- which are the interesting
-- ones. The count is itself a diagnosis: "x412" says this fires constantly.
local function RecordError(text)
  errorsSeen = errorsSeen + 1

  local newest = errorLog[#errorLog]
  if newest and newest.text == text then
    newest.count = newest.count + 1
    return
  end

  errorLog[#errorLog + 1] = {
    text  = text,
    count = 1,
    when  = (type(date) == "function" and date("%H:%M:%S")) or "?",
  }
  if #errorLog > ERROR_LIMIT then table.remove(errorLog, 1) end
end

-- The first Postbox frame on a stack -- and the reason this is not simply a
-- search for "Postbox".
--
-- The stack is taken from inside the trap, and the trap is Postbox code, so
-- its own frames are always on it: a plain search would answer "ours" for
-- every error raised by every addon on the account. What separates them is
-- that the trap lives in Postbox.lua and NOTHING else in the addon does --
-- every other source file is under Core\ or Lib\. So that is the line the
-- filter draws, and it holds however many frames the trap happens to add.
--
-- The cost is that an error raised inside Postbox.lua itself, whose message
-- somehow does not name the file, goes unrecorded. That file is 700 lines of
-- setup and its errors name it; the trade is worth making for a test that
-- cannot produce a false positive.
local function FirstOurFrame(stack)
  for line in stack:gmatch("[^\n]+") do
    if line:find("Postbox[\\/]Core[\\/]") or line:find("Postbox[\\/]Lib[\\/]") then
      return (line:gsub("^%s+", ""))
    end
  end
  return nil
end

-- Ours or not. The message names the file that raised the error, which is
-- the cheap answer and the right one most of the time; when it names someone
-- else's file the error may still be ours, raised inside a Blizzard or
-- library function we called, and only the stack can say so. The stack walk
-- is therefore reached ONLY after the cheap test has already failed, and an
-- error is a rare enough event that one debugstack is not worth optimising.
local function ConsiderError(message)
  local text = tostring(message)
  if text:find("Postbox", 1, true) then
    RecordError(ShortenPath(text))
    return
  end

  if type(debugstack) ~= "function" then return end
  local frame = FirstOurFrame(debugstack(2, 10, 0) or "")
  if not frame then return end

  -- "Their function, blamed on our file" -- the connection is the whole
  -- point of recording an error whose message names someone else.
  RecordError(ShortenPath(text) .. "  <- " .. ShortenPath(frame))
end

if type(geterrorhandler) == "function" and type(seterrorhandler) == "function" then
  local previous = geterrorhandler()
  seterrorhandler(function(message, ...)
    -- Recording must never become the reason an error goes unreported, so it
    -- is wrapped, and the handler that was here before is called either way.
    pcall(ConsiderError, message)
    if type(previous) == "function" then return previous(message, ...) end
  end)
end

-- The event bus pcalls its handlers and logs what they threw, which means a
-- handler error never reaches the trap above -- and event handlers are where
-- a mail addon does most of its work. This is what the bus's logger is
-- pointed at, so both roads end in the same place.
--
-- Everything it is given is recorded, not just the lines saying "error": the
-- bus logs nothing routine. Its three messages are a handler that threw, an
-- event it could not register, and an event this client has never heard of,
-- and the last two are worth a bug report the first time they happen.
local function LogLine(text, ...)
  if type(text) == "string" then pcall(RecordError, ShortenPath(text)) end
  ns.Print(text, ...)
end

-------------------------------------------------------------
-- 5b. The performance record
--
-- "The game freezes for a few seconds when I open the mailbox" arrives from a
-- machine nobody here can sit at, about an inbox nobody here has. The next
-- report has to carry numbers, so each mailbox open is measured: its own
-- stages, then -- for a bounded window after it -- what every inbox update
-- cost, and, at both ends of that window, how many slow frames the game's own
-- addon profiler counted. That last pair is what says whether a freeze during
-- the open was Postbox, some other addon, or not addon code at all.
-- /postbox debug prints it (BuildDiagnosticReport, section 6).
--
-- The window leaves out what the player does later in the same visit, and the
-- close: the profiler charged Postbox slow frames that none of the window's
-- steps accounted for. So the visit is recorded too, on the same open: each
-- tab switch, view switch and first build, every call that asks a bag addon
-- to repaint, and the close with its parts -- one timing per action, not per
-- event -- until the close has been timed.
--
-- The rules, because this rides the one path a player has called slow:
--   * Off unless the player turns it on. Recording is a saved choice -- "off"
--     (the default), "on" or "detail" -- made in the bug report's window or
--     with /postbox perf, and read at login: the hitch a report is wanted for
--     is often the first open after a /reload. Off, ns.Perf is not published
--     at all, so every call site reads nil and carries on exactly as it would
--     with this section gone. The report's profiler and data lines are read
--     when a report is made, whatever the setting.
--   * Nothing is measured away from a mailbox. On, a call site reads ns.Perf,
--     finds no open record (Perf.cur for the window, Perf.visit for the
--     visit), and carries on; a measured step costs two debugprofilestop()
--     calls and a few additions.
--   * The window ends by itself: at the mailbox closing, or at the first
--     measured step more than WINDOW seconds after the open. No timer, no
--     OnUpdate.
--   * On, the record is kept lean: one table per open, allocated once, the
--     profiler read at the window's two ends and at the close, and the
--     padlock verdicts counted rather than timed. The dearest parts -- walking
--     the inbox at a window's end, answering the two item-data events every
--     other addon's item loads fire, and timing each verdict -- are "detail".
--     Even then the item events are listened to only while a window is open.
--     A report walks the inbox for itself while a mailbox is open, either way.
--   * Numbers only, and nothing saved but the choice itself: no character,
--     sender or item name is recorded, and a /reload starts the record afresh
--     (as the profiler itself does).
-------------------------------------------------------------

-- Perf.cur is the open being counted, or nil, Perf.visit the open whose
-- visit is being recorded, or nil, and Perf.detail whether recording is on in
-- detail: the fields a call site may read directly, as the cheapest possible
-- "is anything measuring". Published as ns.Perf only while recording is on
-- (ns.SetPerfRecording, below).
local Perf = {}

do
  local WINDOW = 30         -- seconds after an open that its costs are counted
  local KEEP = 8            -- opens remembered

  -- Enum.AddOnProfilerMetric's values today, for a client that publishes the
  -- profiler without the enum. The enum wins wherever it answers.
  local METRIC = {
    RecentAverageTime = 1, PeakTime = 4,
    CountTimeOver100Ms = 9, CountTimeOver500Ms = 10, CountTimeOver1000Ms = 11,
  }
  local SLOW = { "CountTimeOver100Ms", "CountTimeOver500Ms", "CountTimeOver1000Ms" }
  local STAGES = { "build", "draft", "select", "seed", "refresh", "layout" }
  local ITEM_EVENTS = { "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT" }

  -- The visit's timings (Perf.Done), in the order the report lists them.
  -- ACTS are what the player did. BAGS are the calls that ask a bag addon, or
  -- the client's own bags, to draw again, and their sum is the visit's and
  -- the close's "bags". A verdict is Postbox's own padlock check on one bag
  -- slot: it runs inside those calls and inside the bag addons' own repaints,
  -- so it is counted apart and never stands as the longest step.
  -- "contacts" is a part of a switch to Send, not an action of its own: the
  -- category bar's dimming read from the contact lists, whose first read in
  -- a session (or after a loading screen) builds them -- the guild roster
  -- walked, every name keyed and sorted -- before the tab's first frame.
  local ACTS = { "send", "contacts", "mail", "history", "view", "picker" }
  local BAGS = { "arm", "rearm", "blizz", "baganator", "eui", "eui on show", "slots", "ungrey", "hooks" }
  local IS_BAG = {}
  for i = 1, #BAGS do IS_BAG[BAGS[i]] = true end
  local CLOSE_PARTS = { "memory", "settle", "bags", "draft", "hide" }

  -- A record's numbered slots, which Perf.Open's constructor lays out:
  --     1-15  each timed step of the window: count, total ms and longest ms,
  --           three apiece from KIND_AT[kind];
  --    16-21  each stage's ms, from STAGE_AT[name];
  --    22-48  the profiler's slow-frame counts, nine at a time (the game's
  --           three, all addons' three, Postbox's three): at the open from
  --           SLOW_OPEN, at the window's end from SLOW_END, at the close from
  --           SLOW_CLOSE;
  --    49-96  each visit timing (ACTS, BAGS, then the verdicts'): count, total
  --           ms and longest ms, from ACT_AT[kind];
  --   97-100  the session's first of these, from FIRST_AT[kind]: the Send
  --           tab's first show fills its contact lists, History makes its
  --           rows, the picker its frame;
  --  101-105  each part of the close, from PART_AT[name];
  --  106-112  the named ones below: the bag calls' total ms, the tooltip reads
  --           so far at the open and at the close, the close's clock mark and
  --           its ms, the inbox walk at the window's end, and the memory reads
  --           of reports made during the window.
  -- false is "not yet" (or, for a slow count, "the profiler would not say").
  -- Slots rather than named fields, because a slot costs 16 bytes and a
  -- named field 40, and rather than tables of their own, because this way
  -- an open is one allocation.
  local KIND_AT = { sync = 1, refresh = 4, rows = 7, capture = 10, summary = 13 }
  local STAGE_AT = {}
  for i = 1, #STAGES do STAGE_AT[STAGES[i]] = 15 + i end
  local SLOW_OPEN, SLOW_END, SLOW_CLOSE = 22, 31, 40
  local ACT_AT = {}
  for i = 1, #ACTS do ACT_AT[ACTS[i]] = 46 + 3 * i end
  for i = 1, #BAGS do ACT_AT[BAGS[i]] = 64 + 3 * i end
  ACT_AT.verdict = 94
  local FIRST_AT = { send = 97, contacts = 98, history = 99, picker = 100 }
  local PART_AT = {}
  for i = 1, #CLOSE_PARTS do PART_AT[CLOSE_PARTS[i]] = 100 + i end
  local BAG_MS, SCANS, SCANS_END, CLOSE_AT, CLOSE_MS, END_WALK, REPORT_MS =
    106, 107, 108, 109, 110, 111, 112

  local opens, count = {}, 0
  local firstDone = {}      -- which of FIRST_AT this session has already timed
  local lastInbox = nil     -- the inbox as last read at a mailbox
  -- Without detail, the counts the last visit's updates read, in the one
  -- table this keeps for them.
  local lastCounts = { counts = true, shown = 0, total = 0, at = "?" }
  local watching = false
  local itemFrame = nil     -- detail's item-event listener, made on first use
  local memoryReadMs = 0    -- the costliest memory read a report has made

  -- What is recording now: "off", "on" or "detail". The saved choice
  -- (Core/MailboxUI.lua, UI.GetPerfRecord) is the truth; this follows it at
  -- login and at every change made through the switch below.
  local MODES = { off = true, on = true, detail = true }
  local mode = "off"

  Perf.detail = false

  -- Milliseconds, high resolution: what every duration here is measured in.
  local Clock = type(debugprofilestop) == "function" and debugprofilestop
    or function() return 0 end

  -- Clamped: another addon calling debugprofilestart moves the clock's origin,
  -- and one step measured across that would come out negative.
  local function Since(mark)
    local ms = Clock() - mark
    return ms > 0 and ms or 0
  end

  -- Seconds, and the frame's own clock: the same for everything that runs
  -- within one frame, which is what makes it the frame counter below.
  local function Now()
    return type(GetTime) == "function" and GetTime() or 0
  end

  local function MetricId(name)
    local enum = type(Enum) == "table" and Enum.AddOnProfilerMetric
    local id = type(enum) == "table" and enum[name]
    return type(id) == "number" and id or METRIC[name]
  end

  -- The profiler, or nil and the reason there is none to read.
  local function Profiler()
    local api = C_AddOnProfiler
    if type(api) ~= "table" or type(api.GetApplicationMetric) ~= "function" then
      return nil, "not on this client"
    end
    if type(api.IsEnabled) == "function" then
      local ok, on = pcall(api.IsEnabled)
      if ok and not on then return nil, "profiler off" end
    end
    return api
  end

  local function Metric(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if not ok or type(value) ~= "number" then return nil end
    if type(issecretvalue) == "function" and issecretvalue(value) then return nil end
    return value
  end

  -- Frames over 100 / 500 / 1000 ms so far this session, into t[at] onwards:
  -- the whole game's three, all addons' together, Postbox's alone.
  -- -> whether the profiler answered at all.
  local function SlowInto(t, at)
    local api = Profiler()
    if not api then return false end
    for i = 1, #SLOW do
      local id = MetricId(SLOW[i])
      t[at + i - 1] = Metric(api.GetApplicationMetric, id) or false
      t[at + i + 2] = Metric(api.GetOverallMetric, id) or false
      t[at + i + 5] = Metric(api.GetAddOnMetric, ADDON_NAME, id) or false
    end
    return true
  end

  -- The same counts now, in a table of their own (from slot 1): for a report.
  local function SlowCounts()
    local t = {}
    if SlowInto(t, 1) then return t end
    return nil
  end

  local function InboxCount()
    if type(GetInboxNumItems) ~= "function" then return 0, 0 end
    local ok, shown, total = pcall(GetInboxNumItems)
    if not ok then return 0, 0 end
    shown = tonumber(shown) or 0
    return shown, tonumber(total) or shown
  end

  -- The tooltip reads the padlock verdicts have made this session
  -- (Lib/InventoryLock.lua): the costly part of a verdict.
  local function TooltipScans()
    local lock = ns.Core and ns.Core.InventoryLock
    return lock and tonumber(lock.tooltipScans) or 0
  end

  -- What the inbox holds, as counts. One walk, at a window's end with detail
  -- on, or for a report; never per event.
  local function InboxSummary()
    if type(GetInboxHeaderInfo) ~= "function" then return nil end
    local shown, total = InboxCount()
    local s = { shown = shown, total = total, withItems = 0, slots = 0, cold = 0,
                auction = 0, cod = 0, done = 0, unloaded = 0 }
    local Mail = ns.MailService or {}
    local slotsMax = tonumber(Mail.MAX_ATTACHMENTS) or 16
    local cached = type(C_Item) == "table" and C_Item.IsItemDataCachedByID or nil
    local canScan = type(GetInboxItem) == "function" and type(cached) == "function"
    for index = 1, shown do
      local _, _, sender, subject, _, cod, _, itemCount = GetInboxHeaderInfo(index)
      if sender == nil and subject == nil then
        s.unloaded = s.unloaded + 1
      else
        itemCount = tonumber(itemCount) or 0
        if itemCount > 0 then
          s.withItems = s.withItems + 1
          s.slots = s.slots + itemCount
        end
        if (tonumber(cod) or 0) > 0 then s.cod = s.cod + 1 end
        if type(Mail.ClassifyMail) == "function" then
          local ok, kind = pcall(Mail.ClassifyMail, index)
          if ok and kind and kind ~= "other" then s.auction = s.auction + 1 end
        end
        if type(Mail.IsReadPersistent) == "function" then
          local ok, done = pcall(Mail.IsReadPersistent, index)
          if ok and done then s.done = s.done + 1 end
        end
        -- Attachments can sit in any of the slots, so the walk goes until the
        -- header's count of them has been found rather than through all 16.
        if itemCount > 0 and canScan then
          local found = 0
          for slot = 1, slotsMax do
            local _, itemID = GetInboxItem(index, slot)
            if itemID then
              if not cached(itemID) then s.cold = s.cold + 1 end
              found = found + 1
              if found >= itemCount then break end
            end
          end
        end
      end
    end
    return s
  end

  -- Perf.cur and not Perf.Live(): the window's end is noticed by the steps
  -- around this, and one GetTime per item event was most of its cost.
  local function OnItemData()
    local rec = Perf.cur
    if rec then rec.items = rec.items + 1 end
  end

  -- Checked first, and the registration pcalled as well: a client that has
  -- dropped one of these events must not throw from here.
  local function EventKnown(name)
    local utils = C_EventUtils
    if type(utils) ~= "table" or type(utils.IsEventValid) ~= "function" then return false end
    local ok, valid = pcall(utils.IsEventValid, name)
    return ok and valid == true
  end

  -- A frame of its own rather than the event bus. A window ends inside
  -- another event's dispatch (the close, or an inbox update past its time),
  -- where the bus can only mark a handler removed, so both events stayed
  -- registered until each next fired. A frame lets go at once.
  local function WatchItems(on)
    if on == watching then return end
    if on and not itemFrame then
      if type(CreateFrame) ~= "function" then return end
      itemFrame = CreateFrame("Frame")
      itemFrame:SetScript("OnEvent", OnItemData)
    end
    watching = on
    for i = 1, #ITEM_EVENTS do
      local name = ITEM_EVENTS[i]
      if not on then
        pcall(itemFrame.UnregisterEvent, itemFrame, name)
      elseif EventKnown(name) then
        pcall(itemFrame.RegisterEvent, itemFrame, name)
      end
    end
  end

  local function Note(rec, ms, kind)
    if ms > rec.longest then rec.longest, rec.longestKind = ms, kind end
  end

  -- The open being counted, or nil. The window's end is noticed here, by
  -- whatever asks first after it has passed.
  function Perf.Live()
    local rec = Perf.cur
    if not rec then return nil end
    if Now() - rec.openedAt > WINDOW then
      Perf.Settle("timed out")
      return nil
    end
    return rec
  end

  -- The full open path has begun (Core/MailboxUI.lua, OnMailShow). -> a clock
  -- mark for the first Stage.
  --
  -- Every field is named here, false for "not yet", so the record is sized
  -- once and never grows.
  function Perf.Open()
    if Perf.cur then Perf.Settle("reopened") end
    count = count + 1
    local detail = Perf.detail and true or false
    local rec = {
      0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0,              -- KIND_AT
      false, false, false, false, false, false,                      -- STAGE_AT
      false, false, false,  false, false, false,  false, false, false, -- SLOW_OPEN
      false, false, false,  false, false, false,  false, false, false, -- SLOW_END
      false, false, false,  false, false, false,  false, false, false, -- SLOW_CLOSE
      0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0,    -- ACT_AT: ACTS
      0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0,              -- BAGS
      0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0,
      0, 0, 0,                                                       -- verdict
      false, false, false, false,                                    -- FIRST_AT
      false, false, false, false, false,                             -- PART_AT
      0, 0, false, false, false, false, false,                       -- BAG_MS...REPORT_MS
      no = count,
      at = (type(date) == "function" and date("%H:%M")) or "?",
      openedAt = Now(), t0 = 0, show = false,
      evt = 0, frames = 0, lastFrame = false, firstEvt = false, lastEvt = false,
      openShown = 0, openTotal = 0, firstShown = false, firstTotal = false,
      lastShown = false, lastTotal = false,
      walk = 0, binds = 0, items = 0, asks = 0, cold = 0,
      longest = 0, longestKind = false,
      prof = false, profEnd = false, profClose = false, ended = false, span = 0,
      closing = false, verdicts = 0, detail = detail,
    }
    rec.openShown, rec.openTotal = InboxCount()
    rec.prof = SlowInto(rec, SLOW_OPEN)
    rec[SCANS] = TooltipScans()
    opens[(count - 1) % KEEP + 1] = rec
    Perf.cur = rec
    Perf.visit = rec
    if detail then WatchItems(true) end
    rec.t0 = Clock()
    return rec.t0
  end

  -- One stage of the open path, from `since`; `last` closes the open's total.
  -- -> the mark for the next stage.
  function Perf.Stage(name, since, last)
    local rec = Perf.cur
    if not (rec and since) then return nil end
    local at = STAGE_AT[name]
    if at then rec[at] = (rec[at] or 0) + Since(since) end
    -- The total is on the line as it is, so it does not compete for the
    -- longest step; the refresh inside its select stage does, as a refresh.
    if last then rec.show = Since(rec.t0) end
    return Clock()
  end

  -- A measured step: Begin -> mark or nil, End(kind, mark).
  function Perf.Begin()
    if not Perf.Live() then return nil end
    return Clock()
  end

  function Perf.End(kind, mark)
    local rec = Perf.cur
    if not (rec and mark) then return end
    local ms = Since(mark)
    local at = KIND_AT[kind]
    if at then
      rec[at] = rec[at] + 1
      rec[at + 1] = rec[at + 1] + ms
      if ms > rec[at + 2] then rec[at + 2] = ms end
    end
    Note(rec, ms, kind)
  end

  -- The list refresh's walk, up to where it binds rows: a part of the
  -- refresh, so it is added up but never the longest step on its own.
  function Perf.Walk(mark)
    local rec = Perf.cur
    if rec and mark then rec.walk = rec.walk + Since(mark) end
  end

  function Perf.Rows(mark, bound)
    local rec = Perf.cur
    if not (rec and mark) then return end
    rec.binds = rec.binds + (tonumber(bound) or 0)
    Perf.End("rows", mark)
  end

  -- A row asked the client for an item's info by id; `cached` is whether it
  -- had it. An uncached ask is a server request, answered by an item event.
  function Perf.ItemAsk(cached)
    local rec = Perf.Live()
    if not rec then return end
    rec.asks = rec.asks + 1
    if not cached then rec.cold = rec.cold + 1 end
  end

  -- MAIL_INBOX_UPDATE, from the shell's handler. -> a mark for End("sync").
  function Perf.InboxEvent()
    local rec = Perf.Live()
    if not rec then return nil end
    rec.evt = rec.evt + 1
    local now = Now()
    if now ~= rec.lastFrame then
      rec.frames = rec.frames + 1
      rec.lastFrame = now
    end
    rec.firstEvt = rec.firstEvt or (now - rec.openedAt)
    rec.lastEvt = now - rec.openedAt
    local shown, total = InboxCount()
    if not rec.firstShown then rec.firstShown, rec.firstTotal = shown, total end
    rec.lastShown, rec.lastTotal = shown, total
    return Clock()
  end

  -----------------------------------------------------------
  -- The visit: Mark -> clock mark or nil, Done(kind, mark)
  -----------------------------------------------------------

  function Perf.Mark()
    if not Perf.visit then return nil end
    return Clock()
  end

  -- One action or one bag call, on the open it belongs to. -> its ms.
  -- A verdict is also counted by its caller, straight onto rec.verdicts,
  -- and comes here only to be timed, with detail on.
  function Perf.Done(kind, mark)
    local rec = Perf.visit
    if not (rec and mark) then return nil end
    local ms = Since(mark)
    local at = ACT_AT[kind]
    if at then
      rec[at] = rec[at] + 1
      rec[at + 1] = rec[at + 1] + ms
      if ms > rec[at + 2] then rec[at + 2] = ms end
    end
    if IS_BAG[kind] then
      rec[BAG_MS] = rec[BAG_MS] + ms
      if rec.closing then
        local part = PART_AT.bags
        rec[part] = (rec[part] or 0) + ms
      end
    end
    local first = FIRST_AT[kind]
    if first and not firstDone[kind] then
      firstDone[kind] = true
      rec[first] = ms
    end
    if kind ~= "verdict" then Note(rec, ms, kind) end
    return ms
  end

  -- The close, from the first of the handlers that answer it (Mail Memory's
  -- save runs before the shell's close) to the end of the shell's. Both close
  -- signals arrive for one close; the second finds nothing to time.
  function Perf.CloseBegin()
    local rec = Perf.visit
    if not rec or rec.closing then return end
    rec.closing = true
    rec[CLOSE_AT] = Clock()
    -- Read before the window's own end, in the same frame: the close's frame
    -- is counted by the next read, which is the next open's.
    rec.profClose = SlowInto(rec, SLOW_CLOSE)
  end

  function Perf.ClosePart(name, mark)
    local rec = Perf.visit
    if not (rec and rec.closing and mark) then return end
    local at = PART_AT[name]
    if at then rec[at] = (rec[at] or 0) + Since(mark) end
  end

  function Perf.CloseEnd()
    local rec = Perf.visit
    if not (rec and rec.closing) then return end
    rec[CLOSE_MS] = Since(rec[CLOSE_AT])
    rec.closing = false
    rec[SCANS_END] = TooltipScans()
    Perf.visit = nil
  end

  -- The window is over: the mailbox closed, time ran out, or another open
  -- began. Safe to call with nothing open.
  function Perf.Settle(reason)
    local rec = Perf.cur
    if not rec then return end
    Perf.cur = nil
    WatchItems(false)
    rec.ended = reason
    rec.span = Now() - rec.openedAt
    rec.profEnd = SlowInto(rec, SLOW_END)
    -- An open that saw no update has nothing to add. Without detail, the
    -- box is what the last update read.
    local seen = rec.lastShown or 0
    if not Perf.detail then
      if not rec.firstShown then return end
      lastCounts.shown, lastCounts.total, lastCounts.at = seen, rec.lastTotal or seen, rec.at
      lastInbox = lastCounts
      return
    end
    -- With detail, the box is walked. A closing mailbox may already read
    -- empty; that says nothing about the box this open saw, so the counts
    -- its last update read stand in for it. The walk is Postbox's own work,
    -- and at a close it is part of the close.
    local walkAt = Clock()
    local ok, summary = pcall(InboxSummary)
    rec[END_WALK] = Since(walkAt)
    if rec.closing then rec[PART_AT.settle] = rec[END_WALK] end
    if not ok then summary = nil end
    if summary and (summary.shown > 0 or (rec.firstShown and seen == 0)) then
      lastInbox = summary
    elseif seen > 0 then
      lastInbox = { shown = seen, total = rec.lastTotal or seen, partial = true }
    else
      return
    end
    lastInbox.at = rec.at
  end

  -- Detail on or off, now: the switch below's live half. An open still
  -- counting starts or stops its item events now, and the verdicts their
  -- timing; its inbox is walked, or not, by whatever detail says when it
  -- ends.
  function Perf.SetDetail(on)
    on = on and true or false
    Perf.detail = on
    local rec = Perf.Live()
    if not rec then return end
    if on then rec.detail = true end
    WatchItems(on)
  end

  -- The switch, published whatever it says: the bug report's control and
  -- /postbox perf both turn it. `m` is saved, then made live; nil makes the
  -- saved choice live, which is what login does and what follows a reset.
  -- -> the mode now live.
  --
  -- Off ends the open being counted, and its visit with it, and takes the
  -- record down: from then on every call site reads nil. On starts at the
  -- next open, whose stages the record has to see from the beginning.
  function ns.SetPerfRecording(m)
    local UI = ns.MailboxUI
    if m == nil then
      m = UI and type(UI.GetPerfRecord) == "function" and UI.GetPerfRecord() or mode
    elseif not MODES[m] then
      return mode
    else
      if UI and type(UI.SetPerfRecord) == "function" then UI.SetPerfRecord(m) end
      -- Turned on after a mailbox has been open this session (the window is
      -- built at the first open): the session's firsts may have happened
      -- unrecorded, so no later timing is marked as one.
      if mode == "off" and m ~= "off" and UI and UI._frame then
        for kind in pairs(FIRST_AT) do firstDone[kind] = true end
      end
    end
    if not MODES[m] then m = "off" end
    mode = m
    if m == "off" then
      if Perf.cur then Perf.Settle("recording off") end
      Perf.visit = nil
      Perf.detail = false
      ns.Perf = nil
    else
      Perf.SetDetail(m == "detail")
      ns.Perf = Perf
    end
    return mode
  end

  function ns.GetPerfRecording()
    return mode
  end

  -----------------------------------------------------------
  -- The report's block
  -----------------------------------------------------------

  local floor, format, concat = math.floor, string.format, table.concat

  local function Ms(value)
    value = tonumber(value) or 0
    if value < 0.05 then return "0" end
    if value < 10 then return (format("%.1f", value):gsub("%.0$", "")) end
    return format("%d", floor(value + 0.5))
  end

  -- Three counts' differences, "3/1/0": b[bi..bi+2] less a[ai..ai+2].
  local function Triple(a, ai, b, bi)
    local out = {}
    for i = 0, #SLOW - 1 do
      local x, y = a[ai + i], b[bi + i]
      out[i + 1] = (x and y) and format("%d", floor(y - x + 0.5)) or "?"
    end
    return concat(out, "/")
  end

  local function SlowDelta(rec)
    local stop, at, read = rec, SLOW_END, rec.profEnd
    if not rec.ended then
      stop, at = SlowCounts(), 1
      read = stop ~= nil
    end
    if not (rec.prof and read) then return "slow n/a" end
    return format("slow %s, %s, %s", Triple(rec, SLOW_OPEN, stop, at),
      Triple(rec, SLOW_OPEN + 3, stop, at + 3), Triple(rec, SLOW_OPEN + 6, stop, at + 6))
  end

  local function Timed(rec, kind, withMax)
    local at = KIND_AT[kind]
    local n = rec[at]
    if n == 0 then return nil end
    local text = format("%s %dx %sms", kind, n, Ms(rec[at + 1]))
    if withMax then text = text .. " max " .. Ms(rec[at + 2]) end
    return text
  end

  local function OpenLine(rec)
    local parts = {}
    local function put(text) if text then parts[#parts + 1] = text end end

    local span = rec.ended and rec.span or (Now() - rec.openedAt)
    put(format("#%d %s %s %ds", rec.no, rec.at, rec.ended or "still open", floor(span + 0.5)))
    -- The first update's reading and the last one's: the box as it arrived
    -- and as it settled. (At the open itself it always reads empty.)
    if rec.firstShown then
      put(format("inbox %d/%d->%d/%d", rec.firstShown, rec.firstTotal, rec.lastShown, rec.lastTotal))
    else
      put(format("inbox %d/%d", rec.openShown or 0, rec.openTotal or 0))
    end

    if rec.show then
      local stages = {}
      for i = 1, #STAGES do
        local ms = rec[STAGE_AT[STAGES[i]]]
        if ms then stages[#stages + 1] = STAGES[i] .. " " .. Ms(ms) end
      end
      put(format("show %sms (%s)", Ms(rec.show), concat(stages, ", ")))
    else
      put("show unfinished")
    end

    local events = format("evt %d in %d frames", rec.evt, rec.frames)
    if rec.firstEvt then
      events = events .. format(" %.1f-%.1fs", rec.firstEvt, rec.lastEvt)
    end
    put(events .. ", sync " .. Ms(rec[KIND_AT.sync + 1]) .. "ms")

    local refresh = Timed(rec, "refresh", true)
    put(refresh and (refresh .. ", walk " .. Ms(rec.walk)) or "refresh 0")
    local rows = Timed(rec, "rows")
    put(rows and (rows .. ", " .. rec.binds .. " binds"))
    put(Timed(rec, "capture"))
    -- The shell's once-per-frame pass: stuck prune, status line, tab caption.
    put(Timed(rec, "summary"))
    -- Item events are counted only with detail on.
    if rec.detail then
      if rec.items + rec.asks > 0 then
        put(format("item events %d, asked %d (%d cold)", rec.items, rec.asks, rec.cold))
      end
    elseif rec.asks > 0 then
      put(format("items asked %d (%d cold)", rec.asks, rec.cold))
    end
    put(SlowDelta(rec))
    if rec[REPORT_MS] then
      put(format("a report's memory read %sms in the window", Ms(rec[REPORT_MS])))
    end
    if rec.longestKind then
      put(format("longest step %sms %s", Ms(rec.longest), rec.longestKind))
    end
    return "  " .. concat(parts, " | ")
  end

  -- "send 45ms", or "send 3x 60ms max 45"; "(first)" when the session's
  -- first of it fell in this visit.
  local function Act(rec, kind)
    local at = ACT_AT[kind]
    local n = rec[at]
    if n == 0 then return nil end
    local text
    if n == 1 then
      text = format("%s %sms", kind, Ms(rec[at + 1]))
    else
      text = format("%s %dx %sms max %s", kind, n, Ms(rec[at + 1]), Ms(rec[at + 2]))
    end
    local first = FIRST_AT[kind]
    first = first and rec[first]
    if first then
      text = text .. (n == 1 and " (first)" or format(" (first %s)", Ms(first)))
    end
    return text
  end

  -- Postbox's own three slow counts, from a[ai] to b[bi] (each the start of
  -- nine); nil when either end was not read.
  local function OwnSlow(a, ai, b, bi)
    if not (a and b) then return nil end
    return Triple(a, ai + 6, b, bi + 6)
  end

  -- Up to three lines under an open's own: what the player did in the visit,
  -- what the bags were asked to do, and the close. `nextRec` is the open
  -- after this one, whose first profiler read ends this one's time away.
  local function VisitLines(rec, nextRec)
    local out = {}
    local parts = {}
    for i = 1, #ACTS do parts[#parts + 1] = Act(rec, ACTS[i]) end
    -- At a close the inbox read is one of the close's parts, below.
    if rec[END_WALK] and rec.ended == "timed out" then
      parts[#parts + 1] = format("inbox read at the window's end %sms", Ms(rec[END_WALK]))
    end
    if #parts > 0 then out[#out + 1] = "    actions: " .. concat(parts, ", ") end

    parts = {}
    for i = 1, #BAGS do parts[#parts + 1] = Act(rec, BAGS[i]) end
    -- Every verdict is counted; with detail on it is timed as well.
    local v = ACT_AT.verdict
    local timed = rec[v]
    local verdicts = math.max(rec.verdicts, timed)
    local scans = (rec[SCANS_END] or TooltipScans()) - (rec[SCANS] or 0)
    if verdicts > 0 or scans > 0 then
      local counted
      if timed == 0 then
        counted = format("verdicts %d", verdicts)
      elseif timed == verdicts then
        counted = format("verdicts %d in %sms", verdicts, Ms(rec[v + 1]))
      else
        counted = format("verdicts %d (%d timed, %sms)", verdicts, timed, Ms(rec[v + 1]))
      end
      parts[#parts + 1] = format("%s, %d tooltip reads", counted, scans)
    end
    if #parts > 0 then
      out[#out + 1] = format("    bags %sms: %s", Ms(rec[BAG_MS]), concat(parts, ", "))
    end

    parts = {}
    if rec[CLOSE_MS] then
      local each = {}
      for i = 1, #CLOSE_PARTS do
        local ms = rec[PART_AT[CLOSE_PARTS[i]]]
        if ms then each[#each + 1] = CLOSE_PARTS[i] .. " " .. Ms(ms) end
      end
      parts[#parts + 1] = format("close %sms (%s)", Ms(rec[CLOSE_MS]), concat(each, ", "))
    end
    -- Postbox's slow frames that the window did not see: after it ended and
    -- before the close, and from the close to the next open (or to now).
    local live = Perf.visit == rec
    if rec.ended and rec.ended ~= "closed" and rec.ended ~= "reopened" then
      local stop, stopAt = nil, 1
      if rec.profClose then
        stop, stopAt = rec, SLOW_CLOSE
      elseif live then
        stop = SlowCounts()
      end
      local after = OwnSlow(rec.profEnd and rec, SLOW_END, stop, stopAt)
      if after then parts[#parts + 1] = "Postbox slow after the window " .. after end
    end
    if rec.profClose then
      local stop, stopAt
      if nextRec and nextRec.prof then
        stop, stopAt = nextRec, SLOW_OPEN
      else
        stop, stopAt = SlowCounts(), 1
      end
      local away = OwnSlow(rec, SLOW_CLOSE, stop, stopAt)
      if away then
        parts[#parts + 1] = (nextRec and "Postbox slow from the close to the next open "
          or "Postbox slow since the close ") .. away
      end
    end
    if #parts > 0 then out[#out + 1] = "    " .. concat(parts, " | ") end
    return out
  end

  local function InboxLine()
    local summary, when
    local UI = ns.MailboxUI
    if UI and type(UI.IsMailboxOpen) == "function" and UI.IsMailboxOpen() then
      local ok, live = pcall(InboxSummary)
      if ok and live then summary, when = live, "now" end
    end
    if not summary and lastInbox then
      summary, when = lastInbox, "at the " .. tostring(lastInbox.at) .. " visit"
    end
    -- With recording off a visit leaves nothing behind, so all that can be
    -- said is that no mailbox is open now.
    if not summary then
      return mode == "off" and "  Inbox: no mailbox open" or "  Inbox: no mailbox this session"
    end
    if summary.counts then
      return format("  Inbox %s: %d/%d (detail off)", when, summary.shown, summary.total)
    end
    if summary.partial then
      return format("  Inbox %s: %d/%d (the rest was unreadable at close)",
        when, summary.shown, summary.total)
    end
    return format("  Inbox %s: %d/%d | with items %d, slots %d, uncached %d | AH %d | C.O.D. %d | read+empty %d%s",
      when, summary.shown, summary.total, summary.withItems, summary.slots,
      summary.cold, summary.auction, summary.cod, summary.done,
      summary.unloaded > 0 and (" | headers missing " .. summary.unloaded) or "")
  end

  local function ProfilerLines(add)
    local api, why = Profiler()
    if not api then
      add("  Profiler: " .. why)
      return
    end
    local now = SlowCounts() or {}
    local function three(at)
      local out = {}
      for i = 0, #SLOW - 1 do
        local v = now[at + i]
        out[i + 1] = v and format("%d", floor(v + 0.5)) or "?"
      end
      return concat(out, "/")
    end
    local peak = Metric(api.GetAddOnMetric, ADDON_NAME, MetricId("PeakTime"))
    add(format("  Profiler this session, frames over 100/500/1000ms: game %s, addons %s, Postbox %s | Postbox peak %sms, recent avg %.2fms",
      three(1), three(4), three(7), Ms(peak),
      Metric(api.GetAddOnMetric, ADDON_NAME, MetricId("RecentAverageTime")) or 0))

    if type(api.GetTopKAddOnsForMetric) == "function" then
      local ok, top = pcall(api.GetTopKAddOnsForMetric, MetricId("PeakTime"), 5)
      if ok and type(top) == "table" and #top > 0 then
        local names = {}
        for i = 1, #top do
          local entry = top[i]
          if type(entry) == "table" and type(entry.addOnName) == "string" then
            names[#names + 1] = entry.addOnName .. " " .. Ms(entry.metricValue)
          end
        end
        if #names > 0 then add("  Peak ms: " .. concat(names, ", ")) end
      end
    end
    return peak
  end

  local function DataLine()
    local parts = {}
    local get = ns.Store and ns.Store.Get
    if type(get) == "function" then
      local alts, chars = get("alts"), 0
      if type(alts) == "table" then
        for _, names in pairs(alts) do
          if type(names) == "table" then chars = chars + #names end
        end
      end
      parts[#parts + 1] = chars .. " characters"

      local memory, boxes, mails = get("mailMemory"), 0, 0
      if type(memory) == "table" then
        for _, byName in pairs(memory) do
          if type(byName) == "table" then
            for _, snap in pairs(byName) do
              if type(snap) == "table" then
                boxes = boxes + 1
                if type(snap.mails) == "table" then mails = mails + #snap.mails end
              end
            end
          end
        end
      end
      parts[#parts + 1] = format("memory %d boxes, %d mails", boxes, mails)

      local history, entries, most, bytes = get("mailHistory"), 0, 0, 0
      if type(history) == "table" then
        for _, byName in pairs(history) do
          if type(byName) == "table" then
            for _, list in pairs(byName) do
              if type(list) == "table" then
                entries = entries + #list
                if #list > most then most = #list end
                for i = 1, #list do
                  local entry = list[i]
                  if type(entry) == "table" and type(entry.b) == "string" then bytes = bytes + #entry.b end
                end
              end
            end
          end
        end
      end
      parts[#parts + 1] = format("history %d (most %d), letters %d KB", entries, most, floor(bytes / 1024 + 0.5))
    end

    -- The first value only: GetNumGuildMembers and BNGetNumFriends both
    -- return several, and it is the total that is wanted.
    local function counted(label, fn)
      if type(fn) ~= "function" then return end
      local ok, n = pcall(fn)
      n = ok and tonumber(n) or nil
      parts[#parts + 1] = label .. " " .. (n and format("%d", n) or "?")
    end
    counted("stuck", ns.MailService and ns.MailService.StuckEntries)
    if type(IsInGuild) == "function" and IsInGuild() then counted("guild", GetNumGuildMembers) end
    counted("friends", type(C_FriendList) == "table" and C_FriendList.GetNumFriends)
    counted("bnet", BNGetNumFriends)

    -- Asked for here and only here: the update walks every addon's heap, and
    -- the game's profiler may charge that walk to Postbox, which asked for it.
    -- So it is timed, and the report reads the profiler before it.
    local readMs = nil
    if type(UpdateAddOnMemoryUsage) == "function" and type(GetAddOnMemoryUsage) == "function" then
      local mark = Clock()
      local updated = pcall(UpdateAddOnMemoryUsage)
      local spent = Since(mark)
      local ok, kb = pcall(GetAddOnMemoryUsage, ADDON_NAME)
      if updated then readMs = spent end
      if updated and ok and tonumber(kb) then
        parts[#parts + 1] = format("Postbox %d KB (read in %sms)", floor(kb + 0.5), Ms(spent))
      end
    end
    return "  Data: " .. concat(parts, " | "), readMs
  end

  local HEADING = {
    off = "Performance (recording off):",
    on = "Performance (recording on):",
    detail = "Performance (recording on, detailed):",
  }

  -- The block, as lines. Each part is guarded on its own, so one that breaks
  -- costs its line and not the others.
  function Perf.ReportLines()
    local lines = { HEADING[mode] or HEADING.off }
    local function add(text) lines[#lines + 1] = text end
    local ok, text = pcall(InboxLine)
    if ok then add(text) end
    local _, peak = pcall(ProfilerLines, add)

    -- Built before the Data line and added after it: an open still counting
    -- reads the profiler for its line, and every profiler read has to come
    -- before the memory read.
    local openLines, visits = {}, false
    for n = math.max(1, count - KEEP + 1), count do
      local rec = opens[(n - 1) % KEEP + 1]
      local built, line = pcall(OpenLine, rec)
      openLines[#openLines + 1] = built and line or ("  #" .. n .. " unreadable")
      local nextRec = n < count and opens[n % KEEP + 1] or nil
      local got, more = pcall(VisitLines, rec, nextRec)
      if got and type(more) == "table" then
        for i = 1, #more do
          openLines[#openLines + 1] = more[i]
          visits = true
        end
      end
    end

    local readMs
    ok, text, readMs = pcall(DataLine)
    if ok then add(text) end
    -- An earlier report's memory read may be what the profiler saw as
    -- Postbox's slowest moment, and this says so when the two agree.
    if type(peak) == "number" and memoryReadMs > 0
       and math.abs(peak - memoryReadMs) <= memoryReadMs * 0.1 then
      add(format("  Note: Postbox's peak is within 10%% of an earlier report's memory read (%sms), so the peak may be that report.",
        Ms(memoryReadMs)))
    end
    if type(readMs) == "number" then
      if readMs > memoryReadMs then memoryReadMs = readMs end
      -- An open still counting reads the profiler again when it ends.
      local live = Perf.cur
      if live then live[REPORT_MS] = (live[REPORT_MS] or 0) + readMs end
    end

    -- Off, the visits are not recorded, and the report says so and how to
    -- change it: the reader in the window is the one who can. Opens recorded
    -- before it was turned off still follow.
    if mode == "off" then
      if count == 0 then
        add("  Visits: not recorded, because performance recording is off. To record them, set it to On in this window (or type /postbox perf on), then visit the mailbox again.")
        return lines
      end
      add("  Visits: performance recording is off now, so only the opens below, recorded before it was turned off, are here. Set it to On in this window (or type /postbox perf on) to record more.")
    elseif count == 0 then
      add("  Opens: none this session")
      return lines
    end
    add(format("  Last %d opens (slow = frames over 100/500/1000ms in the window: game, addons, Postbox):",
      math.min(count, KEEP)))
    for i = 1, #openLines do add(openLines[i]) end
    if visits then
      add("  (Indented: the whole visit, not only the window. The bag calls run inside the switches and the close; the verdicts inside the bag calls and the bag addons' own repaints.)")
    end
    return lines
  end
end

-------------------------------------------------------------
-- 6. /postbox
--
-- A small diagnostic surface, not a settings interface -- the options live in
-- the cog. "skin" answers the one question a screenshot cannot: which host-UI
-- skin was detected and which code path is actually driving the window. A
-- silent no-skin (wrong EllesmereUI version, host skinning switched off, ElvUI
-- fallback) is otherwise indistinguishable from a broken theme.
-------------------------------------------------------------

-- Which primitives were on offer, not merely whether an API exists. The surface
-- is additive-only, so the version number IS the feature list. It appears only
-- once a facade has actually been handed over, which is a separate event from
-- EllesmereUI exporting the entry point -- hence the third answer.
local function ApiSummary(report)
  if not report.hasAPI then return "no (using compat backend)" end
  if report.apiVersion then return "v" .. tostring(report.apiVersion) end
  return "yes, no handshake"
end

-- Reached when EllesmereUI has nothing to say about itself, which leaves two
-- possibilities and one phrasing rule. The rule: state it as a fact about
-- EllesmereUI, never about timing. Detection is deferred to ADDON_LOADED /
-- PLAYER_LOGIN (see Core/Skin_EllesmereUI.lua), so "not loaded when we looked"
-- would be misleading -- the host global was absent every time we looked, load
-- order included.
local function ReportSkinWithoutEllesmere()
  if _G.ElvUI and ns.Skin then
    ns.Print("Skin: ElvUI.")
    return
  end
  ns.Print("Skin: none. EllesmereUI is not loaded.")
end

local function ReportSkin()
  local Skin = ns.SkinEllesmere
  if not (Skin and Skin.Diagnose) then
    return ReportSkinWithoutEllesmere()
  end

  local report = Skin.Diagnose()

  ns.Print(string.format(
    "EllesmereUI %s | RegisterSkin API: %s | backend: %s | active: %s",
    report.euiVersion, ApiSummary(report), report.backend,
    report.active and "yes" or "NO"))

  -- Why the official callback never arrived, in the cases where it did not:
  -- three causes with three different fixes, and only one of them is a bug.
  if report.silenceText then
    ns.Print("No skin callback: " .. report.silenceText .. ".")
  end

  -- Turning EllesmereUI's third-party skinning off is reload-bound at their
  -- end, so this reads false while the window stays skinned. Saying so beats
  -- letting it look like a setting that does nothing.
  if report.hostEnabled == false and report.active then
    ns.Print("EllesmereUI skinning for Postbox is now off; the current look stays until /reload.")
  end

  -- bgOpacity is the window's ABSOLUTE alpha, not an offset from the host's.
  -- It was once printed with a leading "+", which read as "10% more opaque
  -- than EllesmereUI" -- the opposite of the truth at the low end.
  ns.Print(string.format(
    "Window style: %s | border: %s (size %d) | bg opacity: %d%%",
    report.style, tostring(report.borderStyle), report.borderSize,
    (report.bgOpacity or 0) * 100))

  ns.Print(string.format(
    "Shell art: %s | window built: %s",
    report.shellArt, report.windowBuilt and "yes" or "not yet — open a mailbox"))
end

-- The commands, in the player's language: the ones a player uses first,
-- then the two that exist for a bug report. The words typed stay English.
local HELP_LINES = {
  "HELP_HEAD", "HELP_OPTIONS", "HELP_MAIL", "HELP_RECIPIENTS", "HELP_MINIMAP", "HELP_DEBUG",
  "HELP_TROUBLE", "HELP_SKIN", "HELP_PERF",
}

local function ReportHelp()
  for i = 1, #HELP_LINES do ns.Print(ns.L[HELP_LINES[i]]) end
end

-------------------------------------------------------------
-- The diagnostic snapshot behind the bug-report window (and nothing else:
-- assembled on demand; the one thing gathered ahead of it is section 5b's
-- timing of mailbox opens, while the player has that recording on).
-- Deliberately English -- it exists to be pasted into a GitHub issue and
-- read by the maintainer.
--
-- What goes in is decided by one test: could this line be the difference
-- between reproducing the report and closing it as "cannot reproduce". Every
-- setting qualifies, because half of the bugs anyone files are a setting
-- doing exactly what it says; so does the client's own version of what
-- Postbox is showing, so does anything else installed that touches mail or
-- bags, and so do the errors themselves.
--
-- What stays out: the player's character name, and their addon list in full.
-- This text goes into a public issue tracker, and neither of those changes
-- what can be fixed. The realm does -- connected-realm addressing is a whole
-- class of mail bug -- so the realm is named and the character is not.
-------------------------------------------------------------

-- Every module's diagnostic is defensive in the same way and for the same
-- reason: a bug report must not be the second thing to break. A module that
-- has not loaded, or whose own Diagnose errors, drops its line and the rest
-- of the report survives.
local function Ask(module, method)
  if type(module) ~= "table" or type(module[method]) ~= "function" then return nil end
  local ok, value = pcall(module[method])
  if ok and type(value) == "string" then return value end
  return nil
end

-- Addons that share Postbox's ground: anything that replaces the mailbox,
-- the bags or the container buttons, and anything that reskins other addons'
-- windows. This is not a blocklist -- Postbox is built to coexist with all
-- of them -- it is the first question worth asking about a report nobody can
-- reproduce on a clean install.
local NEIGHBOURS = {
  "ElvUI", "EllesmereUI", "EllesmereUIBlizzardSkin", "TukUI", "NDui",
  "Bagnon", "AdiBags", "ArkInventory", "BetterBags", "Baganator",
  "Combuctor", "Inventorian", "cargBags_Nivaya", "OneBag3", "Sorted",
  "Postal", "BulkMail", "MailOpener", "Mailbox", "OpeningPandorasBox",
  "TradeSkillMaster", "Auctionator", "AuctionHouseSearch", "TSM_Mailing",
  "Masque", "Skinner", "AddOnSkins", "SharedMedia", "BugSack", "BugGrabber",
}

-- Plus anything whose NAME says what it does: the list above can only ever
-- know the addons that existed when it was written, and a mail addon nobody
-- here has heard of is exactly the one worth knowing about.
local NEIGHBOUR_WORDS = { "mail", "bag", "inventory", "postal", "auction" }

local function LooksRelevant(name)
  local lower = name:lower()
  for i = 1, #NEIGHBOUR_WORDS do
    if lower:find(NEIGHBOUR_WORDS[i], 1, true) then return true end
  end
  return false
end

local function NeighbourAddons()
  local loaded = C_AddOns and C_AddOns.IsAddOnLoaded
  local count = C_AddOns and C_AddOns.GetNumAddOns
  local info = C_AddOns and C_AddOns.GetAddOnInfo
  if type(loaded) ~= "function" then return nil end

  local found, seen = {}, {}
  local function note(name, version)
    if seen[name] then return end
    seen[name] = true
    found[#found + 1] = version and version ~= "" and (name .. " " .. version) or name
  end

  -- The known list first, so a report's most useful names are at the front
  -- however many "MyBagSorter" entries the sweep below turns up.
  for i = 1, #NEIGHBOURS do
    local name = NEIGHBOURS[i]
    local ok, isLoaded = pcall(loaded, name)
    if ok and isLoaded then
      -- The version matters for these and not for the swept ones: a report
      -- against EllesmereUI or ElvUI is nearly always a report against one
      -- particular release of it.
      local gotVersion, version = pcall(C_AddOns.GetAddOnMetadata, name, "Version")
      note(name, (gotVersion and type(version) == "string") and version or nil)
    end
  end

  -- The name sweep. Skipped entirely on a client without the enumeration
  -- API rather than guessed at.
  if type(count) == "function" and type(info) == "function" then
    local ok, total = pcall(count)
    if ok and type(total) == "number" then
      for i = 1, total do
        local gotInfo, name = pcall(info, i)
        if gotInfo and type(name) == "string" and name ~= ns.ADDON_NAME
          and LooksRelevant(name) then
          local gotLoaded, isLoaded = pcall(loaded, i)
          if gotLoaded and isLoaded then note(name) end
        end
      end
    end
  end

  if #found == 0 then return nil end
  return table.concat(found, ", ")
end

local function BuildDiagnosticReport()
  local lines = {}
  local function add(text) lines[#lines + 1] = text end

  add(string.format("Postbox %s (%s)", tostring(ns.VERSION), tostring((GetLocale()))))

  -- The client's interface number and the one the TOC was built against.
  -- When those two disagree the addon is running out of date, and half of
  -- what an out-of-date addon does wrong is unfixable and already fixed --
  -- so it is worth establishing on line two rather than three exchanges in.
  local gameVersion, gameBuild, _, clientToc = GetBuildInfo()
  -- GetAddOnInterfaceVersion, not GetAddOnMetadata("Interface"): the metadata
  -- reader answers only for the fields it lists, and Interface is not one of
  -- them, so every report ever filed said "built for ?". With several
  -- interface numbers in the TOC this answers the one the client picked.
  local ourToc
  if C_AddOns and type(C_AddOns.GetAddOnInterfaceVersion) == "function" then
    local ok, value = pcall(C_AddOns.GetAddOnInterfaceVersion, ADDON_NAME)
    if ok then ourToc = value end
  end
  local scale = (UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 0
  add(string.format("WoW %s (%s) | interface %s, built for %s | UI scale %.2f",
    tostring(gameVersion), tostring(gameBuild),
    tostring(clientToc), tostring(ourToc or "?"), scale))

  -- The realm, the faction and the size of the connected group, with no
  -- character name: "sends to the wrong character" and "cannot find my alt"
  -- are both connected-realm bugs, and the group is what decides them.
  local realm = GetRealmName()
  local faction = UnitFactionGroup("player")
  local connected = ""
  if type(GetAutoCompleteRealms) == "function" then
    local ok, realms = pcall(GetAutoCompleteRealms)
    if ok and type(realms) == "table" then
      connected = string.format(" | connected realms %d", #realms)
    end
  end
  add(string.format("Realm: %s (%s)%s",
    tostring(realm), tostring(faction or "?"), connected))

  local UI = ns.MailboxUI
  local options = Ask(UI, "DiagnoseOptions")
  if options then add("Settings: " .. options) end
  local windowState = Ask(UI, "Diagnose")
  if windowState then add("Window: " .. windowState) end
  local sendState = Ask(ns.SendTab, "Diagnose")
  if sendState then add("Send: " .. sendState) end
  local listState = Ask(ns.CollectTab, "Diagnose")
  if listState then add("List: " .. listState) end

  local Skin = ns.SkinEllesmere
  if Skin and type(Skin.Diagnose) == "function" then
    local ok, report = pcall(Skin.Diagnose)
    if ok and type(report) == "table" then
      add(string.format("EllesmereUI %s | backend %s | active %s%s",
        tostring(report.euiVersion), tostring(report.backend),
        report.active and "yes" or "no",
        report.silenceText and (" | " .. tostring(report.silenceText)) or ""))
    end
  end
  add(string.format("Style: %s | ElvUI loaded: %s",
    tostring(ns.SkinAppliedBy or "own"),
    (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("ElvUI")) and "yes" or "no"))

  -- The border and transparency values, from whichever skin is publishing
  -- them. These used to appear only on an EllesmereUI install, because the
  -- only place they were read was inside EllesmereUI's own Diagnose -- so
  -- every report from a Postbox Modern user, which is precisely where these
  -- three settings now live, was silent about all three.
  local paint = ns.Skin
  if paint and type(paint.GetBorderStyle) == "function" then
    local ok, border, size, opacity = pcall(function()
      return paint.GetBorderStyle(), paint.GetBorderSize(), paint.GetBgOpacity()
    end)
    if ok then
      add(string.format("Border: %s (size %s) | bg opacity %d%%",
        tostring(border), tostring(size),
        math.floor((tonumber(opacity) or 0) * 100 + 0.5)))
    end
  end

  local Icon = ns.MinimapButton
  if Icon and type(Icon.GetEnabled) == "function" then
    add(string.format("Minimap icon: %s | host-styled %s | %s | accent %s glow %s shadow %s",
      Icon.GetEnabled() and "on" or "off",
      (Icon.IsHostStyled and Icon.IsHostStyled()) and "yes" or "no",
      tostring(Icon.GetIcon and Icon.GetIcon() or "?"),
      (Icon.GetAccentTint and Icon.GetAccentTint()) and "on" or "off",
      (Icon.GetGlow and Icon.GetGlow()) and "on" or "off",
      (Icon.GetShadow and Icon.GetShadow()) and "on" or "off"))
    if type(Icon.Diagnose) == "function" then
      local ok, state = pcall(Icon.Diagnose)
      if ok and type(state) == "string" then
        add("Minimap state: " .. state)
      end
    end
  end

  local Memory = ns.MailMemory
  if Memory and type(Memory.Diagnose) == "function" then
    local ok, state = pcall(Memory.Diagnose)
    if ok and type(state) == "string" then
      add("Mail memory: " .. state)
    end
  end

  local Collect = ns.CollectTab
  local record = Collect and type(Collect.GetLastRunRecord) == "function"
    and Collect.GetLastRunRecord()
  if record then
    add(string.format("Last bad run: collected %s, refused %s, left %s%s%s",
      tostring(record.collected or 0), tostring(record.refused or 0),
      tostring(record.left or 0),
      record.stopReason and (" (" .. tostring(record.stopReason) .. ")") or "",
      record.reason and (" | game said: " .. tostring(record.reason)) or ""))
  end

  -- How much there is, never who. A recipient list that has grown to four
  -- figures is a performance report; an empty one where the player expected
  -- their alts is a census report. Neither needs a single name.
  local Manager = ns.RecipientManager
  local counts = {}
  if Manager and type(Manager.Count) == "function" then
    local ok, count = pcall(Manager.Count)
    if ok then counts[#counts + 1] = "recipients " .. tostring(count) end
  end
  local altsByRealm = ns.Store and ns.Store.Get and ns.Store.Get("alts")
  if type(altsByRealm) == "table" then
    local realms, characters = 0, 0
    for _, names in pairs(altsByRealm) do
      realms = realms + 1
      if type(names) == "table" then characters = characters + #names end
    end
    counts[#counts + 1] = string.format("own characters %d on %d realms", characters, realms)
  end
  if #counts > 0 then add("Address book: " .. table.concat(counts, " | ")) end

  -- pcall'd like every other contributor: this one walks the whole addon
  -- list through four APIs, and a report that dies on the way to its last
  -- three lines is worse than one without them.
  local gotNeighbours, neighbours = pcall(NeighbourAddons)
  if gotNeighbours and neighbours then add("Also loaded: " .. neighbours) end

  -- What the last few mailbox opens cost, and what the game's own profiler
  -- counted around them (section 5b). Numbers only, like the line above.
  if type(Perf.ReportLines) == "function" then
    local gotPerf, perfLines = pcall(Perf.ReportLines)
    if gotPerf and type(perfLines) == "table" then
      for i = 1, #perfLines do add(perfLines[i]) end
    end
  end

  -- Last, and last for a reason: it is the part a maintainer scrolls to, and
  -- anything appended below it would be missed.
  if #errorLog > 0 then
    add(string.format("Errors this session: %d", errorsSeen))
    for i = 1, #errorLog do
      local entry = errorLog[i]
      add(string.format("  [%s]%s %s", entry.when,
        entry.count > 1 and (" x" .. entry.count) or "", entry.text))
    end
  end

  return table.concat(lines, "\n")
end
ns.BuildDiagnosticReport = BuildDiagnosticReport

local function OpenBugReport()
  local Panel = ns.OptionsPanel
  if Panel and type(Panel.ToggleBugReport) == "function" then
    Panel.ToggleBugReport()
  end
end

local function ToggleMinimapIcon()
  local Icon = ns.MinimapButton
  if Icon and type(Icon.Toggle) == "function" then
    Icon.Toggle()
  end
end

-- Postbox options, away from a mailbox as well: shown if hidden, raised if
-- already up.
local function OpenOptions()
  local Panel = ns.OptionsPanel
  if Panel and type(Panel.Open) == "function" then Panel.Open() end
end

local function OpenRecipientManager()
  -- The manager window arrives in a later load phase and is optional from this
  -- file's point of view; say so rather than erroring on a nil call.
  local Manager = ns.RecipientManager
  if Manager and type(Manager.Toggle) == "function" then
    Manager.Toggle()
  else
    ns.Print(ns.L["RM_NOT_AVAILABLE"])
  end
end

-- One word each, aliases included, and perf's own words after it. A bare
-- /postbox (or /pb) opens the options; help, and anything unrecognised,
-- prints the commands.
local function OpenMailMemory()
  local Memory = ns.MailMemory
  if Memory and type(Memory.Toggle) == "function" then Memory.Toggle() end
end

-- /postbox perf: section 5b's recording, the same saved choice as the bug
-- report's control. Bare, it steps Off -> On -> Detailed -> Off; with a word,
-- it sets that. Said in chat, because nothing on screen changes.
local PERF_NEXT = { off = "on", on = "detail", detail = "off" }
-- Each mode's name and what it does: the bug report's switch says the same.
local PERF_SAID = {
  off = { "PERF_REC_OFF", "PERF_REC_OFF_DESC" },
  on = { "PERF_REC_ON", "PERF_REC_ON_DESC" },
  detail = { "PERF_REC_DETAIL", "PERF_REC_DETAIL_DESC" },
}

local function SetPerfRecording(m)
  local set, get = ns.SetPerfRecording, ns.GetPerfRecording
  if type(set) ~= "function" or type(get) ~= "function" then return end
  m = set(m or PERF_NEXT[get()] or "on")
  local said = PERF_SAID[m] or PERF_SAID.off
  ns.Print(ns.L("PERF_REC_CHAT", ns.L[said[1]]) .. " " .. ns.L[said[2]])
end

local COMMANDS = {
  [""]        = OpenOptions,
  options     = OpenOptions,
  config      = OpenOptions,
  help        = ReportHelp,
  mail        = OpenMailMemory,
  memory      = OpenMailMemory,
  skin        = ReportSkin,
  recipients  = OpenRecipientManager,
  rm          = OpenRecipientManager,
  minimap     = ToggleMinimapIcon,
  debug       = OpenBugReport,
  perf        = function() SetPerfRecording(nil) end,
  ["perf off"] = function() SetPerfRecording("off") end,
  ["perf on"] = function() SetPerfRecording("on") end,
  ["perf detail"] = function() SetPerfRecording("detail") end,
  ["perf detailed"] = function() SetPerfRecording("detail") end,
}

-- The minimap's addon compartment (Postbox.toc names these). The one way to
-- Mail Memory that is always there: the minimap mail icon exists only while
-- this character has mail, and a character with none still wants to see its
-- alts'. Left-click does what the icon's left-click does; right-click the
-- options.
function Postbox_OnAddonCompartmentClick(_, mouseButton)
  if mouseButton == "RightButton" then
    local panel = ns.OptionsPanel
    if panel and panel.Toggle then panel.Toggle() end
    return
  end
  local Memory = ns.MailMemory
  if Memory and Memory.Toggle then Memory.Toggle() end
end

function Postbox_OnAddonCompartmentEnter(_, button)
  GameTooltip:SetOwner(button, "ANCHOR_LEFT")
  GameTooltip:SetText("Postbox")
  GameTooltip:AddLine(ns.L["COMPARTMENT_TIP"], 0.7, 0.7, 0.7, true)
  GameTooltip:Show()
end

function Postbox_OnAddonCompartmentLeave()
  GameTooltip:Hide()
end

SLASH_POSTBOX1 = "/postbox"
SLASH_POSTBOX2 = "/pb"
SlashCmdList["POSTBOX"] = function(input)
  local word = string.lower(string.match(input or "", "^%s*(.-)%s*$"))
  -- One space between words, so "perf  on" is "perf on".
  word = string.gsub(word, "%s+", " ")
  local handler = COMMANDS[word]
  if handler then
    handler()
  else
    ReportHelp()
  end
end

-- A page under the game's Settings > AddOns: a line saying where Postbox's
-- options are, and a button that opens them. Registered once, through the
-- Settings API's own calls (they cross into the game's code through its
-- SettingsInbound, which is how an addon is meant to add a page), and only
-- where the client offers them. The page is Postbox's own frame, which the
-- game shows inside its window; the button opens the options window over it
-- and touches nothing of the game's.
local settingsPage = nil
local function RegisterSettingsPage()
  if settingsPage then return end
  local S = Settings
  if type(S) ~= "table" or type(S.RegisterCanvasLayoutCategory) ~= "function"
      or type(S.RegisterAddOnCategory) ~= "function" then return end
  local page = CreateFrame("Frame")
  page:Hide()
  local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", page, "TOPLEFT", 16, -16)
  title:SetText("Postbox")
  local text = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
  text:SetPoint("RIGHT", page, "RIGHT", -16, 0)
  text:SetJustifyH("LEFT")
  text:SetText(ns.L["SETTINGS_PAGE_TEXT"])
  local button = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
  button:SetText(ns.L["SETTINGS_PAGE_OPEN"])
  local label = button:GetFontString()
  local w = label and label:GetStringWidth() or 0
  button:SetSize(math.max(180, math.ceil(w) + 32), 24)
  button:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -12)
  button:SetScript("OnClick", OpenOptions)
  local ok = pcall(function()
    local category = S.RegisterCanvasLayoutCategory(page, "Postbox")
    S.RegisterAddOnCategory(category)
  end)
  if ok then settingsPage = page end
end

-------------------------------------------------------------
-- 7. Event wiring
-------------------------------------------------------------

-- LogLine, not ns.Print: the bus pcalls its handlers, so an error inside one
-- never reaches the global error handler and would otherwise be the one
-- class of Postbox error the bug report could not see.
ns.Events = ns.Core.Events.NewBus(LogLine)

ns.Events.Register("ADDON_LOADED", function(_, loadedAddon)
  if loadedAddon ~= ADDON_NAME then return end

  -- No saved variables at all: a first install, whose profile starts on the
  -- Postbox style where no host UI is installed (Core/MailboxUI.lua, Initialize).
  ns.freshInstall = type(PostboxDB) ~= "table"
  -- Which release saved what the client restored (section 4b), read before
  -- the schema below adds 1.50's roots to it.
  local savedBy = SavedByRelease(PostboxDB)

  -- Explicit rather than relying on RegisterCurrentAlt's own call: the schema
  -- has to exist before MailboxUI reads a setting out of it, and that must not
  -- depend on whether the census found a usable name.
  EnsureDB()
  RegisterCurrentAlt()

  -- The performance record as the player left it (section 5b), before
  -- anything can open a mailbox: the first open after a /reload is one of
  -- the opens it is for.
  if type(ns.SetPerfRecording) == "function" then ns.SetPerfRecording() end

  local UI = ns.MailboxUI
  if UI and type(UI.Initialize) == "function" then
    UI.Initialize()
  end

  -- The steps that run once (section 4b): after Initialize has carried the
  -- old settings over, before the minimap icon or any skin reads them.
  Upgrade(savedBy)

  local MinimapIcon = ns.MinimapButton
  if MinimapIcon and type(MinimapIcon.Initialize) == "function" then
    MinimapIcon.Initialize()
  end

  RegisterSettingsPage()
end)

-- Repeated at login because UnitLevel is not dependably populated as early as
-- ADDON_LOADED, and repeated on ding because a level recorded once is wrong
-- from the next ding onwards.
ns.Events.Register("PLAYER_LOGIN", function()
  RegisterCurrentAlt()
end)

ns.Events.Register("PLAYER_LEVEL_UP", function(_, newLevel)
  RegisterCurrentAlt(tonumber(newLevel))
end)
