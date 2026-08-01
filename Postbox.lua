local ADDON_NAME, ns = ...

-- Postbox :: the entry point.
--
-- Everything here happens because it has to happen before anything else can:
-- the addon's identity, the two foundation bindings that give the rest of the
-- tree a saved-variables root and a chat printer, the shape of the saved
-- variables themselves, the running census of the player's own characters, the
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
                              -- plus tabCaption (a mode string; see
                              -- MailboxUI.GetTabCaptionMode)
  PROFILE .. ".recipientHistory",
  PROFILE .. ".minimap",      -- minimap mail icon; a table, so its module owns
                              -- it directly (see the note above on booleans)
  "alts",                     -- realm -> array of character names
  "altClasses",               -- realm -> name -> class token
  "recipients",               -- recipient key -> curation state
  "altMeta",                  -- realm -> name -> { level, faction, lastSeen }
  "lastRun",                  -- realm -> name -> last bad collect run
                              -- (see Core/CollectTab.lua, run memory)
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
-- 5. /postbox
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
  ns.Print("           /postbox debug  — open the bug-report window")
  ns.Print(ns.L["RM_SLASH_HELP"])
end

-------------------------------------------------------------
-- The diagnostic snapshot behind the bug-report window (and nothing else:
-- assembled on demand, no background collection). Deliberately English --
-- it exists to be pasted into a GitHub issue and read by the maintainer.
-------------------------------------------------------------
local function BuildDiagnosticReport()
  local lines = {}
  local function add(text) lines[#lines + 1] = text end

  add(string.format("Postbox %s (%s)", tostring(ns.VERSION), tostring((GetLocale()))))

  local gameVersion, gameBuild = GetBuildInfo()
  local scale = (UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 0
  add(string.format("WoW %s (%s) | UI scale %.2f",
    tostring(gameVersion), tostring(gameBuild), scale))

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
local COMMANDS = {
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
-- 6. Event wiring
-------------------------------------------------------------

ns.Events = ns.Core.Events.NewBus(ns.Print)

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
