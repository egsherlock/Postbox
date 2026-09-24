local ADDON_NAME, ns = ...

-- Postbox :: the entry point.
--
-- Everything here happens because it has to happen before anything else can:
-- the addon's identity, the two foundation bindings that give the rest of the
-- tree a saved-variables root and a chat printer, the shape of the saved
-- variables themselves, the running census of the player's own characters, the
-- error trap that has to be in place before there is anything to catch, the
-- slash command, and the event bus every other module registers on.
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
-------------------------------------------------------------

local PROFILE = "profile"

local SCHEMA = {
  PROFILE,                    -- account-wide settings; boolean values only,
                              -- plus two mode strings: tabCaption (see
                              -- MailboxUI.GetTabCaptionMode) and style
                              -- (MailboxUI.GetStyleChoice)
  PROFILE .. ".recipientHistory",
  PROFILE .. ".minimap",      -- minimap mail icon; a table, so its module owns
                              -- it directly (see the note above on booleans)
  "alts",                     -- realm -> array of character names
  "altClasses",               -- realm -> name -> class token
  "recipients",               -- recipient key -> curation state
  "altMeta",                  -- realm -> name -> { level, faction, lastSeen }
  "lastRun",                  -- realm -> name -> last bad collect run
                              -- (see Core/CollectTab.lua, run memory)
  "mailMemory",               -- realm -> name -> last-seen inbox snapshot
                              -- (see Core/MailMemory.lua)
  "mailWatch",                -- realm -> name -> mail known to be on the way
                              -- since the last visit (Core/MailMemory.lua, 2b)
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
  classes[name] = classToken
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

local function ReportHelp()
  ns.Print("Commands:  /postbox skin  — report skin status")
  ns.Print("           /postbox minimap  — toggle the minimap mail icon")
  ns.Print("           /postbox mail  — what your mailboxes held, every character")
  ns.Print("           /postbox debug  — open the bug-report window")
  ns.Print(ns.L["RM_SLASH_HELP"])
end

-------------------------------------------------------------
-- The diagnostic snapshot behind the bug-report window (and nothing else:
-- assembled on demand, no background collection). Deliberately English --
-- it exists to be pasted into a GitHub issue and read by the maintainer.
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

-- One word each, aliases included. Anything unrecognised -- the empty string
-- most of all, since a bare /postbox is how people go looking -- falls through
-- to the help text.
local function OpenMailMemory()
  local Memory = ns.MailMemory
  if Memory and type(Memory.Toggle) == "function" then Memory.Toggle() end
end

local COMMANDS = {
  mail        = OpenMailMemory,
  memory      = OpenMailMemory,
  skin        = ReportSkin,
  recipients  = OpenRecipientManager,
  rm          = OpenRecipientManager,
  minimap     = ToggleMinimapIcon,
  debug       = OpenBugReport,
}

SLASH_POSTBOX1 = "/postbox"
SlashCmdList["POSTBOX"] = function(input)
  local word = string.lower(string.match(input or "", "^%s*(.-)%s*$"))
  local handler = COMMANDS[word]
  if handler then
    handler()
  else
    ReportHelp()
  end
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

  -- Explicit rather than relying on RegisterCurrentAlt's own call: the schema
  -- has to exist before MailboxUI reads a setting out of it, and that must not
  -- depend on whether the census found a usable name.
  EnsureDB()
  RegisterCurrentAlt()

  local UI = ns.MailboxUI
  if UI and type(UI.Initialize) == "function" then
    UI.Initialize()
  end

  local MinimapIcon = ns.MinimapButton
  if MinimapIcon and type(MinimapIcon.Initialize) == "function" then
    MinimapIcon.Initialize()
  end
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
