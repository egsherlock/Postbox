local _, ns = ...

-- =====================================================================
-- Postbox :: character groups
-- ---------------------------------------------------------------------
-- The player's own groups of senders -- "Bank alts", "Crafters", the friend
-- who sends materials -- each with a sweep button of its own in the Mail tab
-- that collects everything those characters sent. It is From alts, narrowed
-- to the characters the player chose (and widened, where they want, to a
-- guildmate or a friend).
--
-- Three parts, in this order below:
--
--   1. THE GROUPS   PostboxDB.charGroups, at the saved-variable root: they are
--                   something the player built, so a Reset of the settings
--                   (which clears `profile`) never touches them. Every write
--                   goes through this file, but for Reset everything, which
--                   empties the table and says so (CG.DataCleared).
--   2. THE BUTTONS  CG.GridButtons(panel): the specs the Mail tab's category
--                   grid draws, one per group that has anyone in it. Nothing
--                   here collects: a group's sweep is the category token
--                   "group:<id>", which Core/MailService.lua's queue builders
--                   resolve through CG.KeySet, and which Core/CollectTab.lua's
--                   run takes like any other category -- bag check, C.O.D.
--                   exclusion, stuck registry, the lot.
--   3. THE EDITOR   one window to create, name, fill, reorder and delete the
--                   groups, opened from the options panel's Mail tab card
--                   and by right-clicking a group's button or From alts in
--                   the grid (CollectTab, RV.GridEdit).
--
-- Nothing here runs away from a mailbox or the editor: no events, no timers.
-- =====================================================================

ns.CharacterGroups = ns.CharacterGroups or {}
local CG = ns.CharacterGroups

local L = ns.L

-------------------------------------------------------------
-- 1. The groups
--
-- PostboxDB.charGroups = {
--   nextId = 4,                       -- ids are handed out once, never reused
--   list = {                          -- the player's order, which is the
--     { id = "1",                     -- buttons' order
--       name = "Bank alts",
--       members = { "Bankalt-ArgentDawn", "Thorin-Kazzak" } },
--   },
-- }
--
-- The id is what the grid knows a group's button by ("group:1"), so it is
-- stable across renames and reorders. A member is always "Name-Realm", with
-- the realm in its normalised form (Recipients.NormalizeRealm): a group is
-- account-wide, and a bare name would mean a different character on every
-- realm the player logs into. Matching is by recipient key (Recipients.Key),
-- exactly as From alts matches, so case and realm spelling never decide it.
-------------------------------------------------------------

local ROOT = "charGroups"
-- As many buttons as a grid has any business holding.
local MAX_GROUPS = 12
-- A group's name is a button's caption; this is a backstop, not a size.
local NAME_MAX = 32
-- What Core/Recipients.lua accepts for a typed name (R.AddManual): live names
-- are two to twelve letters, with headroom for a longer transliteration.
local NAME_MIN_CHARS, NAME_MAX_CHARS, REALM_MAX_CHARS = 2, 24, 48

local EMPTY = {}

local function Helpers() return ns.Helpers end

local function Lower(text)
  local H = Helpers()
  if H and H.Lower then return H.Lower(text) end
  return tostring(text or "")
end

local function Trim(text)
  local H = Helpers()
  if H and H.NormalizeText then return H.NormalizeText(text) end
  return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

-- member or name -> its recipient key, or nil.
local function KeyOf(text)
  local R = ns.Recipients
  if not (R and type(R.Key) == "function") or type(text) ~= "string" then return nil end
  local key = R.Key(text)
  if type(key) ~= "string" or key == "" then return nil end
  return key
end

local function CharCount(text)
  local H = Helpers()
  return (H and H.CharCount) and H.CharCount(text) or #text
end

-- Letters only, and a sensible number of them. %s, %d and %p are ASCII
-- classes under the client's C locale, so an accented or Cyrillic letter
-- passes as it should.
local function LooksLikeName(short, realm)
  if type(short) ~= "string" or short == "" then return false end
  if short:find("[%s%d%p]") then return false end
  local count = CharCount(short)
  if count < NAME_MIN_CHARS or count > NAME_MAX_CHARS then return false end
  return type(realm) == "string" and realm ~= "" and CharCount(realm) <= REALM_MAX_CHARS
end

-- The realm spellings the census knows (lowercased normalised form -> the
-- normalised form), for Canonical below. Rebuilt with the census (section 2).
local realmSpelling = nil

-- Typed or offered text -> the stored form ("Name-Realm") and its key, or
-- nil when the text cannot be a character. A bare name is the player's own
-- realm, resolved NOW, which is the whole reason members are stored
-- qualified. The name is written the way the game writes names (first letter
-- up, the rest down), so "thorin" and "Thorin" are one member, spelled once.
local function Canonical(text)
  local R = ns.Recipients
  if not (R and type(R.Key) == "function") or type(text) ~= "string" then return nil end
  local key, short, realm = R.Key(text)
  if type(key) ~= "string" or key == "" then return nil end
  if not LooksLikeName(short, realm) then return nil end
  local H = Helpers()
  local name = (H and H.Capitalize) and H.Capitalize(Lower(short)) or short
  -- A realm typed in lowercase takes the census's spelling where it knows one.
  local known = realmSpelling and realmSpelling[Lower(realm)]
  return name .. "-" .. (known or ((H and H.Capitalize) and H.Capitalize(realm) or realm)), key
end

local function CleanName(text)
  local name = Trim(text)
  if name == "" then return nil end
  local H = Helpers()
  local at = (H and H.CharBoundary) and H.CharBoundary(name, NAME_MAX) or nil
  if at and at <= #name then name = Trim(name:sub(1, at - 1)) end
  return name ~= "" and name or nil
end

-- Whatever an earlier build, a hand edit or a half-written session left, made
-- into the shape above: tables with string ids, no duplicate ids, names and
-- member lists of the right types, and a nextId past every id in use. Once
-- per session, on the first read; every write after it keeps the shape.
local function Normalize(root)
  if type(root.list) ~= "table" then root.list = {} end
  local kept, seen, top = {}, {}, 0
  for i = 1, #root.list do
    local g = root.list[i]
    if type(g) == "table" then
      local id = g.id
      if type(id) == "number" then id = tostring(id) end
      if type(id) == "string" and id ~= "" and not seen[id] then
        seen[id] = true
        g.id = id
        if type(g.name) ~= "string" then g.name = "" end
        local members = {}
        if type(g.members) == "table" then
          for j = 1, #g.members do
            if type(g.members[j]) == "string" and g.members[j] ~= "" then
              members[#members + 1] = g.members[j]
            end
          end
        end
        g.members = members
        kept[#kept + 1] = g
        local n = tonumber(id)
        if n and n > top then top = n end
      end
    end
  end
  root.list = kept
  if type(root.nextId) ~= "number" or root.nextId <= top then root.nextId = top + 1 end
end

local normalized = false

-- The saved table, shaped. nil only before the store is bound.
local function Data()
  local Store = ns.Store
  if not (Store and type(Store.EnsurePath) == "function") then return nil end
  local root = Store.EnsurePath(ROOT)
  if type(root) ~= "table" then return nil end
  if not normalized or type(root.list) ~= "table" then
    normalized = true
    Normalize(root)
  end
  return root
end

local function Find(id)
  local root = Data()
  if not root or id == nil then return nil end
  id = tostring(id)
  for i = 1, #root.list do
    if root.list[i].id == id then return root.list[i], i end
  end
  return nil
end

-- The groups, in the player's order. The live saved tables: read them, and
-- change them only through the functions below.
function CG.List()
  local root = Data()
  return root and root.list or EMPTY
end

-- A group's caption. Stored names are never empty; this is for one that is.
function CG.DisplayName(group)
  if type(group) ~= "table" then return "" end
  local name = Trim(group.name)
  if name ~= "" then return name end
  return L("GROUPS_DEFAULT_NAME", tonumber(group.id) or 0)
end

-- id -> the set of its members' keys (key -> true). Memoised until the next
-- change, because the queue builder and every count ask for it; read-only.
local keySets = {}

function CG.KeySet(id)
  id = tostring(id or "")
  local set = keySets[id]
  if set then return set end
  set = {}
  local group = Find(id)
  if group then
    for i = 1, #group.members do
      local key = KeyOf(group.members[i])
      if key then set[key] = true end
    end
  end
  -- Not kept while the key builder is missing: an empty answer then would be
  -- remembered as the group's answer for the rest of the session.
  if ns.Recipients then keySets[id] = set end
  return set
end

function CG.HasMember(id, key)
  return key ~= nil and CG.KeySet(id)[key] == true
end

-- The Mail tab's collect panel, or nil before the window is built.
local function CollectPanel()
  local UI = ns.MailboxUI
  local window = UI and UI._frame
  return window and window.Tabs and window.Tabs.collect or nil
end

-- Whatever changed, the grid redraws from the new groups. Only a collect
-- panel on screen is redrawn: a hidden one lays its grid out again when it
-- shows.
local function RefreshGrid()
  local panel = CollectPanel()
  if not (panel and panel.IsShown and panel:IsShown()) then return end
  local CT = ns.CollectTab
  if CT and type(CT.RefreshCategoryButtons) == "function" then
    CT.RefreshCategoryButtons(panel)
  end
end

-- An open editor's list of groups, painted again (section 3): after every
-- change here, since whether a group has a button follows its members, and
-- when the grid's arrangement has moved under it (CG.GridButtons, below).
local FollowEditor

local function Changed()
  for id in pairs(keySets) do keySets[id] = nil end
  RefreshGrid()
  if FollowEditor then FollowEditor(true) end
end

-- The lowest "Group N" not already taken, so a second new group does not
-- arrive wearing the first one's name.
local function DefaultName(root)
  local taken = {}
  for i = 1, #root.list do taken[Lower(CG.DisplayName(root.list[i]))] = true end
  -- Bounded: a template that ignores its number (a missing translation
  -- answers with its own key) must not spin.
  local first = #root.list + 1
  for n = first, first + MAX_GROUPS do
    local name = L("GROUPS_DEFAULT_NAME", n)
    if not taken[Lower(name)] then return name end
  end
  return L("GROUPS_DEFAULT_NAME", first)
end

-- [name] -> the new group's id, or nil at the cap.
function CG.Create(name)
  local root = Data()
  if not root or #root.list >= MAX_GROUPS then return nil end
  local id = tostring(root.nextId)
  root.nextId = root.nextId + 1
  root.list[#root.list + 1] = { id = id, name = CleanName(name) or DefaultName(root), members = {} }
  Changed()
  return id
end

-- true when the stored name changed. An empty name is not stored: the box
-- that typed it puts the old one back when it lets go.
function CG.Rename(id, name)
  local group = Find(id)
  local clean = CleanName(name)
  if not group or not clean or clean == group.name then return false end
  group.name = clean
  Changed()
  return true
end

-- A deleted group's button forgotten by the grid's stored arrangement: its
-- place and whether it was hidden. Only a deletion drops them -- an empty
-- group keeps both for when someone is in it again (CollectTab,
-- RV.KeepGone) -- and it drops them whichever tab is open.
local function ForgetButton(gridId)
  local UI = ns.MailboxUI
  if not (UI and type(UI.GetGridLayout) == "function" and type(UI.SetGridLayout) == "function") then return end
  local stored = UI.GetGridLayout()
  local kept, found = {}, false
  for i = 1, #stored do
    local entry = stored[i]
    if entry.id == gridId then
      found = true
    else
      kept[#kept + 1] = { id = entry.id, shown = entry.shown }
    end
  end
  if found then UI.SetGridLayout(kept) end
end

function CG.Delete(id)
  local root = Data()
  local group, index = Find(id)
  if not (root and group) then return false end
  table.remove(root.list, index)
  ForgetButton("group:" .. group.id)
  Changed()
  return true
end

-- Whether a group's button ("group:<id>") still has a group behind it,
-- empty or not: the grid keeps such a button's place and whether it was
-- hidden until the group is deleted (CollectTab, RV.KeepGone).
function CG.Exists(gridId)
  if type(gridId) ~= "string" then return false end
  local id = gridId:match("^group:(.+)$")
  return id ~= nil and Find(id) ~= nil
end

-- The groups in the order of `ids`; any group the list leaves out keeps its
-- place after them, so a stale list can reorder but never lose a group.
function CG.SetOrder(ids)
  local root = Data()
  if not root or type(ids) ~= "table" then return end
  local byId, placed, order = {}, {}, {}
  for i = 1, #root.list do byId[root.list[i].id] = root.list[i] end
  for i = 1, #ids do
    local group = byId[tostring(ids[i])]
    if group and not placed[group.id] then
      placed[group.id] = true
      order[#order + 1] = group
    end
  end
  for i = 1, #root.list do
    if not placed[root.list[i].id] then order[#order + 1] = root.list[i] end
  end
  local moved = false
  for i = 1, #order do
    if root.list[i] ~= order[i] then moved = true end
    root.list[i] = order[i]
  end
  if moved then Changed() end
end

-- id, name -> the member's key when it is (now) in the group, or nil when
-- the text cannot be a character or the group is gone.
function CG.AddMember(id, text)
  local group = Find(id)
  if not group then return nil end
  local member, key = Canonical(text)
  if not member then return nil end
  if CG.KeySet(id)[key] then return key end
  group.members[#group.members + 1] = member
  Changed()
  return key
end

function CG.RemoveMember(id, key)
  local group = Find(id)
  if not group or key == nil then return false end
  local removed = false
  for i = #group.members, 1, -1 do
    if KeyOf(group.members[i]) == key then
      table.remove(group.members, i)
      removed = true
    end
  end
  if removed then Changed() end
  return removed
end

-------------------------------------------------------------
-- 2. The buttons
--
-- The contract with the category grid (Core/CollectTab.lua):
--
--   CG.GridButtons(panel) -> { spec, ... } in the groups' own order, one per
--   group with at least one member (an empty group has nothing to collect and
--   no button until it does). The panel argument is accepted and not needed:
--   each spec's own functions take the panel they act on. Each spec:
--     id       "group:<id>", stable across renames
--     label    the player's name for the group
--     tooltip  function(tooltip): fills an owned, cleared tooltip -- title
--              and body; the caller shows it
--     count    function(panel) -> what the button would collect right now
--     collect  function(panel): starts the sweep through the collect run
--
-- A button counts the way the category sweeps do: what is listed. With a
-- search or the stuck filter on, that is the rows on screen, and the sweep
-- takes those (CollectTab's StartCategoryRun narrows to panel._filtered in
-- exactly those states). With neither, the listed unfinished rows ARE the
-- inbox's unfinished mail, so counting the list and sweeping the inbox agree.
-------------------------------------------------------------

-- One tally of the listed mail by sender per list walk, however many groups
-- ask: panel._measurePass moves once per walk of the list (Core/CollectTab.lua,
-- CT.RefreshMailList), and the walk's own finished/unfinished verdicts ride
-- along so no mail's sixteen slots are scanned twice.
local tallyMemo = { pass = nil, list = nil, tally = nil }

local function Tally(panel)
  local Mail = ns.MailService
  if not (Mail and type(Mail.SenderTally) == "function") then return EMPTY end
  local list = type(panel) == "table" and panel._filtered or nil
  if type(list) ~= "table" then
    -- No list has been walked: the whole inbox, asked afresh.
    local all = {}
    local n = type(GetInboxNumItems) == "function" and tonumber((GetInboxNumItems())) or 0
    for i = 1, n do all[i] = i end
    return Mail.SenderTally(all)
  end
  local pass = panel._measurePass
  if pass ~= nil and tallyMemo.pass == pass and tallyMemo.list == list then
    return tallyMemo.tally
  end
  local tally = Mail.SenderTally(list, panel._filteredDone)
  tallyMemo.pass, tallyMemo.list, tallyMemo.tally = pass, list, tally
  return tally
end

function CG.Count(panel, id)
  local set = CG.KeySet(id)
  if next(set) == nil then return 0 end
  local tally = Tally(panel)
  local n = 0
  for key in pairs(set) do n = n + (tally[key] or 0) end
  return n
end

function CG.Collect(panel, id)
  panel = panel or CollectPanel()
  local CT = ns.CollectTab
  if not (panel and id ~= nil and CT and type(CT.StartCategoryRun) == "function") then return end
  CT.StartCategoryRun(panel, "group:" .. tostring(id))
end

-- Class colours for names: the census's class for the player's own
-- characters, the contact cache's for anyone else, plain where neither knows.
local function Tint(text, token)
  local CS = ns.ContactService
  if type(token) ~= "string" or not (CS and CS.WrapClass) then return text end
  return CS.WrapClass(token, text)
end

local function Quiet(text)
  local T = ns.Theme
  if T and T.Colorize then return T.Colorize("textSecondary", text) end
  return text
end

-- The census: every character Postbox has seen log in, account-wide.
-- { name, realm (raw), key, member, class, home }, the realm being played
-- first, then by realm, then by name.
local function Census()
  local out = {}
  local Store = ns.Store
  local alts = Store and Store.Get and Store.Get("alts")
  local classes = Store and Store.Get and Store.Get("altClasses")
  local spelling = {}
  realmSpelling = spelling
  if type(alts) ~= "table" then return out end
  local R = ns.Recipients
  local home = type(GetRealmName) == "function" and GetRealmName() or nil
  local seen = {}
  for realm, names in pairs(alts) do
    if type(realm) == "string" and type(names) == "table" then
      if R and type(R.NormalizeRealm) == "function" then
        local norm = R.NormalizeRealm(realm)
        spelling[Lower(norm)] = norm
      end
      local byName = type(classes) == "table" and classes[realm] or nil
      for i = 1, #names do
        local name = names[i]
        if type(name) == "string" and name ~= "" then
          local member, key = Canonical(name .. "-" .. realm)
          if member and not seen[key] then
            seen[key] = true
            out[#out + 1] = {
              name = name, realm = realm, key = key, member = member,
              class = type(byName) == "table" and byName[name] or nil,
              home = (realm == home),
            }
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.home ~= b.home then return a.home end
    if a.realm ~= b.realm then return Lower(a.realm) < Lower(b.realm) end
    return Lower(a.name) < Lower(b.name)
  end)
  return out
end

-- One of the player's characters, as the address book writes it: the name in
-- its class colour, and the realm after it, quieter, when it is not the one
-- being played.
local function AltLabel(c)
  local text = Tint(c.name, c.class)
  if not c.home then text = text .. Quiet("-" .. c.realm) end
  return text
end

-- Anyone else: the address (bare on the realm being played), the name half
-- in its class colour where the contact cache knows it.
local function OtherLabel(member)
  local R = ns.Recipients
  local address = (R and type(R.Address) == "function") and R.Address(member) or member
  if type(address) ~= "string" or address == "" then address = member end
  local short, realm = address:match("^([^%-]+)%-(.+)$")
  short = short or address
  local CS = ns.ContactService
  local name = short
  if CS and type(CS.GetClassColoredName) == "function" then
    local ok, colored = pcall(CS.GetClassColoredName, address, short)
    if ok and type(colored) == "string" then name = colored end
  end
  if realm then name = name .. Quiet("-" .. realm) end
  return name
end

-- key -> census entry, for labelling a group's members.
local function CensusByKey(census)
  local map = {}
  for i = 1, #census do map[census[i].key] = census[i] end
  return map
end

local function MemberLabel(member, byKey)
  local key = KeyOf(member)
  local c = key and byKey[key]
  if c then return AltLabel(c) end
  return OtherLabel(member)
end

-- Who a group's button collects from, for its tooltip: a dozen names, then
-- how many more.
local TIP_NAMES = 12

function CG.FillTooltip(tooltip, id)
  tooltip = tooltip or GameTooltip
  local group = Find(id)
  if not (tooltip and group) then return end
  local byKey = CensusByKey(Census())
  local names = {}
  for i = 1, math.min(#group.members, TIP_NAMES) do
    names[i] = MemberLabel(group.members[i], byKey)
  end
  local text = table.concat(names, ", ")
  local more = #group.members - TIP_NAMES
  if more > 0 then text = text .. " " .. ns.Plural("GROUPS_TIP_MORE", more) end
  tooltip:SetText(CG.DisplayName(group))
  tooltip:AddLine(L("GROUPS_TIP_FROM", text), 1, 1, 1, true)
  local T = ns.Theme
  local r, g, b = 0.6, 0.6, 0.6
  local grey = T and T.Colors and T.Colors.textSecondary
  if type(grey) == "table" then r, g, b = grey[1], grey[2], grey[3] end
  tooltip:AddLine(L["GROUPS_TIP_EDIT"], r, g, b, true)
end

-- The line From alts' tooltip carries, so the player who already uses it
-- learns that it can be split up. For the grid to add under its own text.
function CG.AltsTooltip(tooltip)
  tooltip = tooltip or GameTooltip
  if not tooltip then return end
  local T = ns.Theme
  local r, g, b = 0.6, 0.6, 0.6
  local grey = T and T.Colors and T.Colors.textSecondary
  if type(grey) == "table" then r, g, b = grey[1], grey[2], grey[3] end
  tooltip:AddLine(L["GROUPS_TIP_ALTS"], r, g, b, true)
end

-- Specs are kept per group so the grid's closures are made once, not on
-- every refresh; the label is re-read every time. The closures hold the id
-- and nothing else: the panel is the one the grid passes on each call.
local specs = {}

function CG.GridButtons()
  local out = {}
  local list = CG.List()
  for i = 1, #list do
    local group = list[i]
    if #group.members > 0 then
      local id = group.id
      local spec = specs[id]
      if not spec then
        spec = {
          id = "group:" .. id,
          tooltip = function(tooltip) CG.FillTooltip(tooltip, id) end,
          count = function(panel) return CG.Count(panel, id) end,
          collect = function(panel) CG.Collect(panel, id) end,
        }
        specs[id] = spec
      end
      spec.label = CG.DisplayName(group)
      out[#out + 1] = spec
    end
  end
  -- The grid asks for its buttons on every layout, and lays itself out after
  -- every change to its arrangement, which the arrange mode stores first
  -- (MailboxUI.SetGridLayout) and redraws after. An open editor takes the
  -- ask as its cue to see whether the arrangement it marked has moved. Its
  -- failure is its own: the grid keeps its buttons.
  if CG._editor and FollowEditor then
    local ok, err = pcall(FollowEditor, false)
    if not ok and type(geterrorhandler) == "function" then geterrorhandler()(err) end
  end
  return out
end

-- Whether the arrange mode hid a group's button ("group:<id>"): the grid's
-- stored arrangement, read as it stands (MailboxUI.GridIdHidden). Whether
-- the group has a button at all is the caller's to ask first: an empty one
-- has none to hide.
local function ButtonHidden(gridId)
  local UI = ns.MailboxUI
  return UI ~= nil and type(UI.GridIdHidden) == "function" and UI.GridIdHidden(gridId) or false
end

-- A group's hidden button shown again, as the arrange mode shows one: the
-- stored arrangement with that one entry on, written through the setter the
-- mode writes with, and the grid laid out from it -- which an open arrange
-- mode's inspector follows (CollectTab, CT.RefreshCategoryButtons). The rest
-- is written back as it was read, and the grid reconciles it as before.
-- -> true when the button was hidden.
function CG.ShowButton(id)
  local UI = ns.MailboxUI
  if not (UI and type(UI.GetGridLayout) == "function" and type(UI.SetGridLayout) == "function") then
    return false
  end
  local gridId = "group:" .. tostring(id)
  if not ButtonHidden(gridId) then return false end
  local stored = UI.GetGridLayout()
  local entries = {}
  for i = 1, #stored do
    local entry = stored[i]
    entries[i] = { id = entry.id, shown = entry.shown or entry.id == gridId }
  end
  UI.SetGridLayout(entries)
  RefreshGrid()
  if FollowEditor then FollowEditor(false) end
  return true
end

-------------------------------------------------------------
-- 3. The editor
--
-- One window, two panes. Left: the groups, in button order, each with a grip
-- to drag it up or down, and New group under them. Right: the selected
-- group -- its name, and the characters it collects from, ticked. One box
-- above that list both finds and adds: typing narrows the list to the
-- matching characters, offers the guildmates, friends and recent contacts
-- who match, and -- when what is typed can be a character's name and nobody
-- listed is it -- offers to add exactly that name. Enter takes the obvious
-- one. With no groups at all the window is one sentence and one button.
--
-- The list also says where each group's button is. A group with its button
-- in the grid is just its name. The two that have none on screen step their
-- name down and carry a mark at the row's right end: a crossed eye where the
-- arrange mode hid the button (a click shows it again), and a quiet note
-- while nobody is in the group, which has no button yet. The list follows
-- both while it is open: every change to the groups repaints it, and so does
-- the grid's arrangement moving under it. While the Mail tab's category
-- buttons are off, one quiet line under the panes says that no group has a
-- button until they are on again.
-------------------------------------------------------------

local EDITOR_W, EDITOR_H = 480, 430
local TOP = 32
local LIST_W = 150
local GROUP_ROW_H = 22
local MEMBER_ROW_H = 20
local GRIP_W = 10
-- Contacts offered for a typed query, at most: a list to pick from, not the
-- guild roster.
local MAX_SUGGESTIONS = 8

local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"

local POPUP_DELETE = "POSTBOX_GROUP_DELETE"

local function EnsureDeleteDialog()
  if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then return false end
  if StaticPopupDialogs[POPUP_DELETE] then return true end
  StaticPopupDialogs[POPUP_DELETE] = {
    text = "%s",
    button1 = L["RM_BTN_DELETE"],
    button2 = L["COD_CONFIRM_CANCEL"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, data)
      if type(data) == "table" and type(data.onConfirm) == "function" then data.onConfirm() end
    end,
  }
  return true
end

local function PlayTick(on)
  if type(PlaySound) ~= "function" or type(SOUNDKIT) ~= "table" then return end
  PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
end

-- Forward declarations: the rows and the panes paint each other.
local Paint, PaintGroupRows, PaintHeader, RebuildMembers, ToggleEntry

local function Selected(frame)
  return Find(frame.selected)
end

local function Select(frame, id)
  if frame.selected == id then return end
  frame.selected = id
  if frame.NameBox then frame.NameBox:ClearFocus() end
  -- A query was a question about the last group's list.
  if frame.Search and frame.Search.Box:GetText() ~= "" then
    frame.Search.Box:SetText("")
  end
  if frame.Scroll then frame.Scroll:SetVerticalScroll(0) end
  Paint(frame)
end

local function NewGroup(frame)
  local id = CG.Create()
  if not id then return end
  frame.selected = nil
  Select(frame, id)
  -- Straight into naming it: the default is selected, so typing replaces it.
  frame.NameBox:SetFocus()
  frame.NameBox:HighlightText()
end

local function DeleteSelected(frame)
  local group, index = Selected(frame)
  if not group then return end
  local id = group.id
  local function Remove()
    CG.Delete(id)
    local list = CG.List()
    -- The group that took its place, or the one above it at the end.
    local neighbour = list[index] or list[#list]
    frame.selected = neighbour and neighbour.id or nil
    if frame:IsShown() then Paint(frame) end
  end
  -- Nothing ticked is nothing to lose: no question.
  if #group.members == 0 or not EnsureDeleteDialog() then
    Remove()
    return
  end
  -- Lifted over this window, which is a strata above where a popup opens.
  ns.Theme.LiftPopup(StaticPopup_Show(POPUP_DELETE, L("GROUPS_DELETE_CONFIRM", CG.DisplayName(group)), nil,
    { onConfirm = Remove }))
end

-- The selection's look, as the Mail tab's selected rows wear it: the accent
-- at a low alpha over the stripe, and a bar at the left edge.
local function PaintSelection(row, on)
  if on then
    local r, g, b = ns.Theme.GetAccent()
    row.Wash:SetColorTexture(r, g, b, 0.14)
    row.Bar:SetColorTexture(r, g, b, 0.9)
  end
  row.Wash:SetShown(on)
  row.Bar:SetShown(on)
end

-- A group row: grip, name. Built on first need and reused.
local function GroupRow(frame, i)
  local row = frame.GroupRows[i]
  if row then return row end
  local T = ns.Theme

  row = CreateFrame("Button", nil, frame.GroupList)
  row:SetHeight(GROUP_ROW_H)
  row:RegisterForClicks("LeftButtonUp")

  row.Wash = row:CreateTexture(nil, "BACKGROUND", nil, 1)
  row.Wash:SetAllPoints()
  row.Bar = row:CreateTexture(nil, "ARTWORK")
  row.Bar:SetWidth(2)
  row.Bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
  row.Bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
  PaintSelection(row, false)

  -- The grip: three short rules, the options panel's sign for "this moves".
  -- It is the only drag handle; the row's own click selects.
  local grip = CreateFrame("Frame", nil, row)
  grip:SetSize(GRIP_W, GROUP_ROW_H)
  grip:SetPoint("LEFT", row, "LEFT", 6, 0)
  grip:EnableMouse(true)
  grip:RegisterForDrag("LeftButton")
  grip.lines = {}
  for n = 1, 3 do
    local line = grip:CreateTexture(nil, "ARTWORK")
    line:SetSize(GRIP_W, 1)
    line:SetPoint("CENTER", grip, "CENTER", 0, (2 - n) * 4)
    line:SetTexture(WHITE)
    T.SetColor(line, "textSecondary")
    line:SetAlpha(0.6)
    grip.lines[n] = line
  end
  local function Lit(alpha) for n = 1, 3 do grip.lines[n]:SetAlpha(alpha) end end
  grip:SetScript("OnEnter", function(self)
    Lit(1)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["GROUPS_DRAG_TIP"])
    GameTooltip:Show()
  end)
  grip:SetScript("OnLeave", function() Lit(0.6) GameTooltip:Hide() end)
  grip:SetScript("OnDragStart", function()
    GameTooltip:Hide()
    local scale = row:GetEffectiveScale()
    local _, cursorY = GetCursorPosition()
    row._grab = (row:GetTop() or 0) - cursorY / scale
    row._dragging = true
    row:SetFrameLevel(row:GetFrameLevel() + 10)
    -- Scoped to the drag: set here, cleared on the drop (or the window closing).
    row:SetScript("OnUpdate", function(self)
      local _, y = GetCursorPosition()
      local offset = (y / scale + self._grab) - (frame.GroupList:GetTop() or 0)
      -- Kept inside the list, between its first and last slot.
      local lowest = -1 - (#CG.List() - 1) * GROUP_ROW_H
      if offset > -1 then offset = -1 end
      if offset < lowest then offset = lowest end
      self:ClearAllPoints()
      self:SetPoint("TOPLEFT", frame.GroupList, "TOPLEFT", 1, offset)
      self:SetPoint("TOPRIGHT", frame.GroupList, "TOPRIGHT", -1, offset)
    end)
  end)
  grip:SetScript("OnDragStop", function()
    row:SetScript("OnUpdate", nil)
    if not row._dragging then return end
    row._dragging = false
    row:SetFrameLevel(math.max(row:GetFrameLevel() - 10, 0))
    -- The new order is the rows' order down the list, the dragged one
    -- included, read from where each one's middle now stands.
    local shown = {}
    for n = 1, #CG.List() do
      if frame.GroupRows[n] and frame.GroupRows[n]:IsShown() then shown[#shown + 1] = frame.GroupRows[n] end
    end
    table.sort(shown, function(p, q)
      local _, py = p:GetCenter()
      local _, qy = q:GetCenter()
      return (py or 0) > (qy or 0)
    end)
    local ids = {}
    for n = 1, #shown do ids[n] = shown[n].groupId end
    CG.SetOrder(ids)
    PaintGroupRows(frame)
  end)
  row.Grip = grip

  row.Name = T.CreateText(row, "bodySmall")
  row.Name:SetPoint("LEFT", grip, "RIGHT", 6, 0)
  row.Name:SetJustifyH("LEFT")
  row.Name:SetWordWrap(false)

  -- The crossed eye, tinted as the arrange mode tints its hidden marks and
  -- set in from the row's right end by the name's own margin. Its own
  -- control: pointed at, it lights and the row stays lit under it; a click
  -- shows the button and leaves the selection where it was.
  local eye = CreateFrame("Button", nil, row)
  eye:RegisterForClicks("LeftButtonUp")
  eye.Glyph = T.Glyph(eye, "eye-off", 8)
  local glyphW = 0
  if eye.Glyph then
    eye.Glyph:SetPoint("CENTER", eye, "CENTER", 0, 0)
    T.SetColor(eye.Glyph, "textDisabled")
    glyphW = eye.Glyph:GetWidth() or 0
  end
  eye:SetSize(glyphW + 2 * 6, GROUP_ROW_H)
  eye:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  eye:SetScript("OnEnter", function(self)
    T.StyleMailRow(row, row.position, true)
    if self.Glyph then T.SetColor(self.Glyph, "textSecondary") end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["GROUPS_HIDDEN_TIP"], 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  eye:SetScript("OnLeave", function(self)
    T.StyleMailRow(row, row.position, false)
    if self.Glyph then T.SetColor(self.Glyph, "textDisabled") end
    GameTooltip:Hide()
  end)
  eye:SetScript("OnClick", function()
    GameTooltip:Hide()
    if CG.ShowButton(row.groupId) then PlayTick(true) end
  end)
  eye:Hide()
  row.Eye = eye

  -- The note an empty group's row carries, in the quietest grey.
  row.Note = T.CreateText(row, "secondary")
  row.Note:SetPoint("RIGHT", row, "RIGHT", -6, 0)
  row.Note:SetJustifyH("RIGHT")
  row.Note:SetWordWrap(false)
  T.SetColor(row.Note, "textDisabled")
  row.Note:Hide()

  row:SetScript("OnClick", function(self) Select(frame, self.groupId) end)
  row:SetScript("OnEnter", function(self)
    T.StyleMailRow(self, self.position, true)
    if self.__pbOverflowText then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(self.__pbOverflowText, 1, 1, 1, 1, true)
      GameTooltip:Show()
    end
  end)
  row:SetScript("OnLeave", function(self)
    T.StyleMailRow(self, self.position, false)
    GameTooltip:Hide()
  end)

  frame.GroupRows[i] = row
  frame._createdRows = true
  return row
end

-- An empty group's note, fitted into the room the row has for text (`room`,
-- the name's whole width): at its own width, or -- where a translation or a
-- host font runs long -- cut to leave the name a third of that room, so the
-- note gives way before the name does. -> the width it takes.
local function FitNote(row, room)
  local T = ns.Theme
  local most = math.floor(room * 2 / 3) - 6
  T.FitText(row.Note, most, L["GROUPS_NO_BUTTON"])
  return math.min(T.TextWidth(row.Note), most)
end

-- Whether the Mail tab's category buttons are off, so no group has one.
local function ButtonsOff()
  local UI = ns.MailboxUI
  return UI ~= nil and type(UI.GetOption) == "function" and not UI.GetOption("showCategoryButtons")
end

function PaintGroupRows(frame)
  local T = ns.Theme
  local list = CG.List()
  local UI = ns.MailboxUI
  local layout = UI and type(UI.GetGridLayout) == "function" and UI.GetGridLayout() or EMPTY
  -- The arrangement these marks were read from, and whether the buttons
  -- were on, for FollowEditor.
  frame._gridSeen = layout
  frame._buttonsOff = ButtonsOff()
  frame.ButtonsOff:SetShown(frame._buttonsOff)
  local room = (frame.GroupList:GetWidth() or LIST_W) - 2 - (6 + GRIP_W + 6) - 6
  for i = 1, #list do
    local group = list[i]
    local row = GroupRow(frame, i)
    if row.groupId ~= group.id then
      row.groupId = group.id
      row.gridId = "group:" .. group.id
    end
    row.position = i
    if not row._dragging then
      local y = -1 - (i - 1) * GROUP_ROW_H
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", frame.GroupList, "TOPLEFT", 1, y)
      row:SetPoint("TOPRIGHT", frame.GroupList, "TOPRIGHT", -1, y)
    end
    T.StyleMailRow(row, i, false)
    PaintSelection(row, group.id == frame.selected)
    -- Where the group's button is: nowhere while nobody is in the group,
    -- hidden where the arrange mode hid it, else in the grid. The name reads
    -- a grey quieter for each step away from the grid, and only the two
    -- exceptions carry a mark, which takes its room from the name's end.
    local empty = #group.members == 0
    local hidden = not empty and ButtonHidden(row.gridId)
    local width = room
    if hidden then
      width = room - (row.Eye.Glyph and row.Eye.Glyph:GetWidth() or 0) - 6
    elseif empty then
      width = room - FitNote(row, room) - 6
    end
    row.Eye:SetShown(hidden)
    row.Note:SetShown(empty)
    T.FitText(row.Name, width, CG.DisplayName(group), row)
    T.SetColor(row.Name, (empty and "textDisabled") or (hidden and "textSecondary") or "textPrimary")
    row:Show()
  end
  for i = #list + 1, #frame.GroupRows do frame.GroupRows[i]:Hide() end
  frame.NewButton:SetEnabled(#list < MAX_GROUPS)
end

-- The list again, while the window is open: `always` after a change to the
-- groups, else only when the grid's arrangement is no longer the one its
-- marks were read from (MailboxUI hands back the same table for as long as
-- the stored arrangement is the same), or the category buttons were turned
-- on or off since.
function FollowEditor(always)
  local frame = CG._editor
  if not (frame and frame:IsShown()) then return end
  if not always then
    local UI = ns.MailboxUI
    local layout = UI and type(UI.GetGridLayout) == "function" and UI.GetGridLayout() or EMPTY
    if layout == frame._gridSeen and ButtonsOff() == frame._buttonsOff then return end
  end
  PaintGroupRows(frame)
end

-- The line over the member list: how many characters the group holds.
function PaintHeader(frame)
  local group = Selected(frame)
  local n = group and #group.members or 0
  frame.Count:SetText(n > 0 and ns.Plural("GROUPS_MEMBER_COUNT", n) or L["GROUPS_NONE_YET"])
end

-- A member-list row: a checkbox and a name, or a heading, or the offer to
-- add what was typed. Built on first need and reused; every bind re-anchors.
local function MemberRow(frame, i)
  local row = frame.MemberRows[i]
  if row then return row end
  local T = ns.Theme

  row = CreateFrame("Button", nil, frame.ListChild)
  row:SetHeight(MEMBER_ROW_H)
  row:RegisterForClicks("LeftButtonUp")

  row.Check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
  row.Check:SetSize(MEMBER_ROW_H, MEMBER_ROW_H)
  row.Check:SetPoint("LEFT", row, "LEFT", 4, 0)
  -- The skins find the box by this tag and its caption by __label.
  row.Check.__postboxCheck = true

  row.Plus = T.CreateText(row, "value")
  row.Plus:SetPoint("CENTER", row.Check, "CENTER", 0, 0)
  row.Plus:SetText("+")
  T.SetColor(row.Plus, "textSecondary")

  row.Tag = T.CreateText(row, "secondary")
  row.Tag:SetPoint("RIGHT", row, "RIGHT", -6, 0)
  row.Tag:SetJustifyH("RIGHT")
  row.Tag:SetWordWrap(false)

  row.Text = T.CreateText(row, "bodySmall")
  row.Text:SetJustifyH("LEFT")
  row.Text:SetWordWrap(false)
  row.Check.__label = row.Text

  local function Act() ToggleEntry(frame, row) end
  row:SetScript("OnClick", Act)
  row.Check:SetScript("OnClick", Act)
  row:SetScript("OnEnter", function(self) T.StyleMailRow(self, self.position, true) end)
  row:SetScript("OnLeave", function(self) T.StyleMailRow(self, self.position, false) end)

  frame.MemberRows[i] = row
  frame._createdRows = true
  return row
end

local function BindMember(frame, row, entry, i)
  local T = ns.Theme
  row.entry = entry
  row.position = i
  local y = -((i - 1) * MEMBER_ROW_H)
  row:ClearAllPoints()
  row:SetPoint("TOPLEFT", frame.ListChild, "TOPLEFT", 0, y)
  row:SetPoint("TOPRIGHT", frame.ListChild, "TOPRIGHT", 0, y)

  local kind = entry.kind
  local acts = (kind == "member" or kind == "add")
  row:EnableMouse(acts)
  row.Check:SetShown(kind == "member")
  row.Plus:SetShown(kind == "add")
  if kind == "member" then row.Check:SetChecked(CG.HasMember(frame.selected, entry.key)) end

  -- Only when the row changes kind: a skin that re-fonted the label keeps it.
  local role = (kind == "heading" and "heading") or (kind == "note" and "secondary") or "bodySmall"
  if row._role ~= role then
    T.ApplyTextRole(row.Text, role)
    row._role = role
  end
  row.Text:ClearAllPoints()
  if acts then
    row.Text:SetPoint("LEFT", row.Check, "RIGHT", 2, 0)
  else
    row.Text:SetPoint("LEFT", row, "LEFT", 8, 0)
  end
  row.Text:SetPoint("RIGHT", row.Tag, "LEFT", -6, 0)
  row.Text:SetText(entry.text or "")
  row.Tag:SetText(entry.tag or "")

  -- Stripes on the rows that act; a heading is a heading, not a row.
  T.StyleMailRow(row, i, false)
  if row._bg then row._bg:SetShown(acts) end
  row:Show()
end

-- Whether a name answers the query: its own spelling, its key (which holds
-- the realm without spaces), or name and realm as the census writes them.
local function Matches(query, ...)
  if query == "" then return true end
  for n = 1, select("#", ...) do
    local text = select(n, ...)
    if type(text) == "string" and Lower(text):find(query, 1, true) then return true end
  end
  return false
end

-- The contacts a typed query finds, beyond the player's own characters, in
-- the order a player reaches for them, each with the word for where it came
-- from.
local SUGGESTION_SOURCES = {
  { list = "friends",   tag = "CONTACT_FRIENDS" },
  { list = "guild",     tag = "CONTACT_GUILD" },
  { list = "recent",    tag = "CONTACT_RECENT" },
  { list = "grouped",   tag = "CONTACT_RECENTLY_GROUPED" },
  { list = "favorites" },
  { list = "manual" },
  { list = "other" },
}

local function Suggestions(text)
  local CS = ns.ContactService
  if not (CS and type(CS.BuildSuggestions) == "function") then return nil end
  local ok, results = pcall(CS.BuildSuggestions, text)
  if not ok or type(results) ~= "table" then return nil end
  return results
end

function RebuildMembers(frame)
  local group = Selected(frame)
  local entries = {}
  frame._entries = entries
  if not group then
    for i = 1, #frame.MemberRows do frame.MemberRows[i]:Hide() end
    return
  end

  local raw = Trim(frame.Search and frame.Search.Box:GetText() or "")
  local query = Lower(raw)
  local census = Census()
  local byKey = CensusByKey(census)
  local listed = {}

  -- Your characters.
  local yours = {}
  for i = 1, #census do
    local c = census[i]
    if Matches(query, c.name, c.key, c.name .. "-" .. c.realm) then
      yours[#yours + 1] = { kind = "member", key = c.key, member = c.member, text = AltLabel(c) }
      listed[c.key] = true
    end
  end
  if #yours > 0 then
    entries[#entries + 1] = { kind = "heading", text = L["GROUPS_YOURS"] }
    for i = 1, #yours do entries[#entries + 1] = yours[i] end
  end

  -- Other players: this group's own, then whoever the query finds.
  local others = {}
  for i = 1, #group.members do
    local member = group.members[i]
    local key = KeyOf(member)
    if key and not byKey[key] and not listed[key] and Matches(query, member, key) then
      others[#others + 1] = { kind = "member", key = key, member = member, text = OtherLabel(member) }
      listed[key] = true
    end
  end
  local add
  if query ~= "" then
    local results = Suggestions(raw)
    local offered = 0
    if results then
      for s = 1, #SUGGESTION_SOURCES do
        local source = SUGGESTION_SOURCES[s]
        local addresses = results[source.list]
        if type(addresses) == "table" then
          for i = 1, #addresses do
            if offered >= MAX_SUGGESTIONS then break end
            local member, key = Canonical(addresses[i])
            if member and not listed[key] and not byKey[key] then
              others[#others + 1] = {
                kind = "member", key = key, member = member, text = OtherLabel(member),
                tag = source.tag and L[source.tag] or nil,
              }
              listed[key] = true
              offered = offered + 1
            end
          end
        end
      end
    end
    -- What was typed, exactly, when it can be a name and nobody above is it.
    local member, key = Canonical(raw)
    if member and not listed[key] then
      local R = ns.Recipients
      local shown = (R and type(R.Address) == "function") and R.Address(member) or member
      add = { kind = "add", key = key, member = member, text = L("GROUPS_ADD", shown) }
    end
  end
  if #others > 0 or add then
    entries[#entries + 1] = { kind = "heading", text = L["GROUPS_OTHERS"] }
    for i = 1, #others do entries[#entries + 1] = others[i] end
    if add then entries[#entries + 1] = add end
  end

  if #entries == 0 then
    entries[1] = { kind = "note", text = L["EMPTY_LIST_SEARCH"] }
  end

  for i = 1, #entries do BindMember(frame, MemberRow(frame, i), entries[i], i) end
  for i = #entries + 1, #frame.MemberRows do
    frame.MemberRows[i].entry = nil
    frame.MemberRows[i]:Hide()
  end
  frame.ListChild:SetHeight(math.max(1, #entries * MEMBER_ROW_H))
  local scroll = frame.Scroll
  local most = math.max(0, #entries * MEMBER_ROW_H - (scroll:GetHeight() or 0))
  if (scroll:GetVerticalScroll() or 0) > most then scroll:SetVerticalScroll(most) end
  if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
  -- Rows built since the last pass (here or in the group list) have never
  -- been through the skin.
  if frame._createdRows then
    frame._createdRows = false
    if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, frame) end
  end
end

-- A click on a member row, its box, or the offer to add.
function ToggleEntry(frame, row)
  local entry = row.entry
  local id = frame.selected
  if not (entry and id) then return end
  -- The groups' list follows from CG.AddMember and CG.RemoveMember
  -- themselves (Changed); the header and the box are this pane's.
  if entry.kind == "add" then
    if CG.AddMember(id, entry.member) then
      PlayTick(true)
      PaintHeader(frame)
      -- The list comes back whole, with the new name ticked in it.
      frame.Search.Box:SetText("")
    end
    return
  end
  if entry.kind ~= "member" then return end
  local on = not CG.HasMember(id, entry.key)
  if on then
    CG.AddMember(id, entry.member)
  else
    CG.RemoveMember(id, entry.key)
  end
  -- The row stays where it is, ticked or not: a list that closed up under the
  -- cursor would hand the next click to a different name.
  row.Check:SetChecked(CG.HasMember(id, entry.key))
  PlayTick(on)
  PaintHeader(frame)
end

-- Enter in the find-or-add box takes the obvious one: the name typed, when a
-- row is exactly it; else the only row the query left; else, when the query
-- found nobody at all, the offer to add what was typed. Several matches are
-- not obvious, so Enter then does nothing. It only ever ticks -- Enter never
-- takes anyone out -- and it clears the box for the next name.
local function EnterPressed(frame)
  local entries = frame._entries or EMPTY
  local raw = Trim(frame.Search.Box:GetText() or "")
  if raw == "" then return false end
  local _, typedKey = Canonical(raw)
  local target, only, offer
  local count = 0
  for i = 1, #entries do
    local e = entries[i]
    if e.kind == "member" then
      count = count + 1
      only = e
      if typedKey and e.key == typedKey then target = e end
    elseif e.kind == "add" then
      offer = e
    end
  end
  if not target then
    if count == 1 then
      target = only
    elseif count == 0 then
      target = offer
    end
  end
  if not target then return false end
  if not CG.HasMember(frame.selected, target.key) then
    if not CG.AddMember(frame.selected, target.member) then return false end
    PlayTick(true)
    PaintHeader(frame)
  end
  frame.Search.Box:SetText("")
  return true
end

-- The right pane from the selected group; the name box is left alone while
-- the player is typing in it.
local function PaintEditor(frame)
  local group = Selected(frame)
  if not group then return end
  if not frame.NameBox:HasFocus() then frame.NameBox:SetText(group.name or "") end
  PaintHeader(frame)
  RebuildMembers(frame)
end

function Paint(frame)
  local list = CG.List()
  local empty = #list == 0
  frame.EmptyState:SetShown(empty)
  for i = 1, #frame.EditParts do frame.EditParts[i]:SetShown(not empty) end
  if empty then
    frame.selected = nil
    for i = 1, #frame.GroupRows do frame.GroupRows[i]:Hide() end
    frame.ButtonsOff:Hide()
    return
  end
  if not Find(frame.selected) then frame.selected = list[1].id end
  PaintGroupRows(frame)
  PaintEditor(frame)
end

local function Build()
  if CG._editor then return CG._editor end
  local T = ns.Theme
  local M = T.Metrics
  local PAD = M.inset
  local BUTTON_H = M.buttonHeight

  -- Named: Escape closes it through UISpecialFrames, which is a list of names.
  local frame = CreateFrame("Frame", "PostboxCharacterGroupsFrame", UIParent,
                            "BasicFrameTemplateWithInset")
  frame:SetSize(EDITOR_W, EDITOR_H)
  -- The options panel's strata, raised above it on open: this is where its
  -- Character groups button leads.
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:Hide()
  -- An editor is read while it is used: legible whatever opacity the mailbox
  -- window runs at. Skin.ApplyBgOpacity honours this flag.
  frame.__pbEuiAlwaysOpaque = true

  if frame.SetTitle then
    frame:SetTitle(L["GROUPS_TITLE"])
  elseif frame.TitleText then
    frame.TitleText:SetText(L["GROUPS_TITLE"])
  end
  T.ApplyFrameTheme(frame)
  ns.Core.UI.Helpers.RegisterEscClose(frame)

  frame.GroupRows, frame.MemberRows, frame.EditParts = {}, {}, {}
  local parts = frame.EditParts

  -- Left: the groups, and New group under them.
  local list = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  list:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -TOP)
  list:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD + BUTTON_H + M.gap)
  list:SetWidth(LIST_W)
  T.ApplyList(list)
  frame.GroupList = list
  parts[#parts + 1] = list

  local new = T.CreateButton(nil, frame)
  new:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD)
  new:SetSize(LIST_W, BUTTON_H)
  new:SetText(L["GROUPS_NEW"])
  new:SetScript("OnClick", function() NewGroup(frame) end)
  -- Disabled at the cap, and still says why.
  if new.SetMotionScriptsWhileDisabled then new:SetMotionScriptsWhileDisabled(true) end
  new:SetScript("OnEnter", function(self)
    if self:IsEnabled() then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["GROUPS_NEW"])
    GameTooltip:AddLine(L["GROUPS_FULL"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  new:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.NewButton = new
  parts[#parts + 1] = new

  -- Right: the selected group.
  local left = PAD + LIST_W + PAD

  local nameCaption = T.CreateText(frame, "label")
  nameCaption:SetPoint("TOPLEFT", frame, "TOPLEFT", left, -TOP)
  nameCaption:SetText(L["GROUPS_NAME"])
  parts[#parts + 1] = nameCaption

  local paneW = EDITOR_W - left - PAD
  local nameWrap = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  nameWrap:SetPoint("TOPLEFT", nameCaption, "BOTTOMLEFT", 0, -(M.labelGap + 2))
  nameWrap:SetSize(paneW, M.controlHeight)
  local nameBox = CreateFrame("EditBox", nil, nameWrap)
  T.StyleInput(nameWrap, nameBox)
  nameBox:SetAutoFocus(false)
  local font = T.FontObject and T.FontObject("bodySmall")
  if font then nameBox:SetFontObject(font) end
  T.SetColor(nameBox, "textPrimary")
  nameBox:SetPoint("TOPLEFT", nameWrap, "TOPLEFT", 8, -2)
  nameBox:SetPoint("BOTTOMRIGHT", nameWrap, "BOTTOMRIGHT", -8, 2)
  nameBox:SetMaxLetters(NAME_MAX)
  nameWrap:SetScript("OnMouseDown", function() nameBox:SetFocus() end)
  -- Renamed as it is typed: the list and the button follow the keystrokes
  -- (CG.Rename repaints both).
  nameBox:SetScript("OnTextChanged", function(self, userInput)
    if not userInput or not frame.selected then return end
    CG.Rename(frame.selected, self:GetText())
  end)
  nameBox:SetScript("OnEditFocusGained", function(self)
    local group = Selected(frame)
    self._before = group and group.name or nil
  end)
  -- Letting go of an empty box puts the stored name back.
  nameBox:SetScript("OnEditFocusLost", function(self)
    self:HighlightText(0, 0)
    local group = Selected(frame)
    if group then self:SetText(group.name or "") end
  end)
  nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  -- Escape undoes this round of typing, as it does in the game's own boxes.
  nameBox:SetScript("OnEscapePressed", function(self)
    if self._before and frame.selected then CG.Rename(frame.selected, self._before) end
    self:ClearFocus()
  end)
  frame.NameBox = nameBox
  parts[#parts + 1] = nameWrap

  local membersCaption = T.CreateText(frame, "label")
  membersCaption:SetPoint("TOPLEFT", nameWrap, "BOTTOMLEFT", 0, -M.sectionGap)
  membersCaption:SetText(L["GROUPS_MEMBERS"])
  parts[#parts + 1] = membersCaption

  local search = T.CreateSearchBox(frame, paneW, M.controlHeight, L["GROUPS_SEARCH"], {
    onTextChanged = function()
      if frame.Scroll then frame.Scroll:SetVerticalScroll(0) end
      RebuildMembers(frame)
    end,
  })
  search.Wrap:SetPoint("TOPLEFT", membersCaption, "BOTTOMLEFT", 0, -(M.labelGap + 2))
  search.Box:SetScript("OnEnterPressed", function(self)
    if not EnterPressed(frame) then self:ClearFocus() end
  end)
  frame.Search = search
  parts[#parts + 1] = search.Wrap

  -- How many the group holds, on the caption's line at the pane's right edge
  -- (one anchor, taken from the box under both).
  local count = T.CreateText(frame, "secondary")
  count:SetPoint("BOTTOMRIGHT", search.Wrap, "TOPRIGHT", 0, M.labelGap + 2)
  count:SetJustifyH("RIGHT")
  count:SetWordWrap(false)
  frame.Count = count
  parts[#parts + 1] = count

  local card = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  card:SetPoint("TOPLEFT", search.Wrap, "BOTTOMLEFT", 0, -M.gap)
  card:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD + BUTTON_H + M.gap)
  T.ApplyList(card)
  parts[#parts + 1] = card

  -- The rows run to the card's edge while nothing scrolls, and stop short of
  -- the bar only while it is there (Theme's slim bar calls __pbGutter).
  local gutter = M.scrollGutter or 16
  local scroll = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
  scroll:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -gutter, 1)
  if scroll.SetClipsChildren then scroll:SetClipsChildren(true) end
  scroll.__pbGutter = function(scrolling)
    scroll:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -(scrolling and gutter or 1), 1)
  end
  T.SlimScrollBar(scroll, card, 1)
  frame.Scroll = scroll

  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(EDITOR_W - left - PAD - 2 - gutter, 1)
  scroll:SetScrollChild(child)
  scroll:HookScript("OnSizeChanged", function(_, width)
    if width and width > 10 then child:SetWidth(width) end
  end)
  frame.ListChild = child

  local delete = T.CreateButton(nil, frame)
  delete:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD)
  delete:SetText(L["GROUPS_DELETE"])
  T.SizeToText(delete, { minWidth = 96, height = BUTTON_H })
  delete:SetScript("OnClick", function() DeleteSelected(frame) end)
  parts[#parts + 1] = delete

  -- While the category buttons are off no group has a button, whatever its
  -- row says: said once, quietly, between the two buttons under the panes
  -- (PaintGroupRows), on two lines where a language runs long.
  local off = T.CreateText(frame, "secondary")
  off:SetPoint("LEFT", new, "RIGHT", M.gap, 0)
  off:SetPoint("RIGHT", delete, "LEFT", -M.gap, 0)
  off:SetJustifyH("CENTER")
  off:SetWordWrap(true)
  if off.SetMaxLines then off:SetMaxLines(2) end
  T.SetColor(off, "textDisabled")
  off:SetText(L["GROUPS_BUTTONS_OFF"])
  off:Hide()
  frame.ButtonsOff = off

  -- No groups yet: what they are, in one sentence, and the one way to start.
  local emptyState = CreateFrame("Frame", nil, frame)
  emptyState:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -TOP)
  emptyState:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD)
  local explain = T.CreateText(emptyState, "body")
  explain:SetPoint("CENTER", emptyState, "CENTER", 0, 24)
  explain:SetWidth(EDITOR_W - 6 * PAD)
  explain:SetJustifyH("CENTER")
  explain:SetWordWrap(true)
  explain:SetText(L["GROUPS_EMPTY"])
  local start = T.CreateButton(nil, emptyState)
  start:SetText(L["GROUPS_NEW"])
  T.SizeToText(start, { minWidth = LIST_W, height = BUTTON_H })
  start:SetPoint("TOP", explain, "BOTTOM", 0, -M.sectionGap)
  start:SetScript("OnClick", function() NewGroup(frame) end)
  emptyState:Hide()
  frame.EmptyState = emptyState

  -- Closing mid-drag or mid-typing leaves nothing running or half-said.
  frame:SetScript("OnHide", function(self)
    for i = 1, #self.GroupRows do
      local row = self.GroupRows[i]
      if row._dragging then
        row:SetScript("OnUpdate", nil)
        row._dragging = false
        row:SetFrameLevel(math.max(row:GetFrameLevel() - 10, 0))
      end
    end
    self.NameBox:ClearFocus()
    self.Search.Box:ClearFocus()
    GameTooltip:Hide()
    -- When: an Escape whose close-windows pass closed this window over the
    -- arrange mode (in combat, where the mode cannot hear the key first) is
    -- this window's, not a layer of the mode's (Arrange.lua, section 5).
    -- Otherwise the mode closes it itself, as a layer of its own.
    CG._hiddenAt = GetTime()
  end)

  -- Same expression as the options panel and Mail Memory: let an active
  -- host-UI skin restyle the shell, whichever entry point it offers.
  local applyWindow = ns.Skin and (ns.Skin.ApplyWindow or ns.Skin.Apply)
  if applyWindow then applyWindow(frame) end

  CG._editor = frame
  return frame
end

-- Where the window opens: beside the mailbox window when that is up, beside
-- the options panel when that is, else the middle of the screen. Beside
-- means the side with room for it -- right first, or `side` first where the
-- caller names one (-1 the left: the arrange mode's inspector, docked on
-- the window's left, opens it away from the window) -- compared in screen
-- pixels, since the windows can carry different scales. Clamped, so a
-- window with no room either side still lands whole.
local function Place(frame, anchor, side)
  if not anchor then
    local UI = ns.MailboxUI
    local window = UI and UI._frame
    local options = ns.OptionsPanel and ns.OptionsPanel._frame
    if window and window:IsShown() then
      anchor = window
    elseif options and options:IsShown() then
      anchor = options
    end
  end
  frame:ClearAllPoints()
  local left = anchor and anchor.GetLeft and anchor:GetLeft()
  local right = anchor and anchor.GetRight and anchor:GetRight()
  if not (left and right) then
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    return
  end
  local scale = anchor:GetEffectiveScale() or 1
  local own = EDITOR_W * (frame:GetEffectiveScale() or 1)
  local screen = (UIParent:GetRight() or 0) * (UIParent:GetEffectiveScale() or 1)
  local fitsRight = right * scale + 8 + own <= screen
  local fitsLeft = left * scale - 8 - own >= 0
  local goLeft
  if side == -1 then
    goLeft = fitsLeft or not fitsRight
  else
    goLeft = not fitsRight and fitsLeft
  end
  if goLeft then
    frame:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -8, 0)
  else
    frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
  end
end

-- [id or "group:<id>"] [, anchor [, side]] -> the editor, open on that
-- group (or on the one it last showed), beside `anchor` on `side` first
-- where there is room (Place). Raises it when it is already open.
function CG.OpenEditor(id, anchor, side)
  local frame = Build()
  if type(id) == "string" then id = id:match("^group:(.+)$") or id end
  local opening = not frame:IsShown()
  if opening then
    Place(frame, anchor, side)
    frame.Scroll:SetVerticalScroll(0)
  end
  frame:Show()
  frame:Raise()
  if id ~= nil and Find(id) and frame.selected ~= tostring(id) then
    Select(frame, tostring(id))
  else
    Paint(frame)
  end
  if opening and ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, frame) end
  return frame
end

function CG.CloseEditor()
  if CG._editor then CG._editor:Hide() end
end

function CG.EditorShown()
  return CG._editor ~= nil and CG._editor:IsShown()
end

-- The groups were emptied from outside this file (Options, Reset
-- everything): the saved table is the same one, bare, and Data() shapes it
-- again on its next read. What was remembered about the old groups goes,
-- and an open editor shows the none that is left. The caller redraws the
-- Mail tab's grid.
function CG.DataCleared()
  normalized = false
  for id in pairs(keySets) do keySets[id] = nil end
  local frame = CG._editor
  if not frame then return end
  frame.selected = nil
  if frame.NameBox then frame.NameBox:ClearFocus() end
  if frame.Search and frame.Search.Box then frame.Search.Box:SetText("") end
  if frame:IsShown() then Paint(frame) end
end
