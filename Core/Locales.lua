local _, ns = ...

-------------------------------------------------------------
-- Every string the addon shows, and how one of them is chosen
--
-- There is a single table, ns.L, and this file fills it in two passes. The
-- first block writes the complete English set. Then at most one locale block
-- runs and overwrites the entries it has a translation for -- so a block only
-- ever needs to carry what it has actually translated, and anything it leaves
-- alone keeps its English text rather than coming out blank.
--
-- Two ways to read a string:
--
--     ns.L["BTN_BACK"]               -- as written
--     ns.L("RM_META_LEVEL", 70)      -- with the arguments applied
--
-- A key nobody wrote answers with itself, so a string that was never added
-- appears in game as RM_SOME_KEY. That is loud on purpose: silence, or an
-- error inside SetText, would both be worse than an obviously wrong label.
--
-- Counted strings use neither form. They are families of keys read through
-- ns.Plural, immediately below.
-------------------------------------------------------------

local L = {}
ns.L = setmetatable(L, {
  -- An absent key resolves to the key itself; see the note above.
  __index = function(_, key) return key end,
  -- Calling the table formats: L("KEY", a, b) == L["KEY"]:format(a, b).
  __call = function(self, key, ...)
    local s = self[key]
    if select("#", ...) > 0 then return s:format(...) end
    return s
  end,
})

-------------------------------------------------------------
-- Plurals
--
-- Never build a counted string by hand. "%d slot" .. (n > 1 and "s" or "")
-- shipped in every one of the five locales, so a Russian player read an English
-- "slots"; and there is no suffix rule that works for Russian anyway, which
-- needs three forms selected on the last digit AND the last two digits.
--
-- A counted string is declared as a family of keys and read through ns.Plural:
--
--     L["COUNT_SLOTS_ONE"]   = "%d slot"
--     L["COUNT_SLOTS_OTHER"] = "%d slots"
--
--     ns.Plural("COUNT_SLOTS", n)          --> "1 slot" / "4 slots"
--     ns.Plural("COUNT_MAILS", n, extra)   --> n is always the first format arg
--
-- A locale declares only the forms its rule can select. Russian declares
-- _ONE / _FEW / _MANY; everything else declares _ONE / _OTHER. Nothing ever
-- falls back to an English suffix: a family with no usable form renders the key
-- itself, which is loud, in-game, and obviously a missing translation.
-------------------------------------------------------------

-- Resolution order per selected form. Each chain ends somewhere a two-form
-- locale has declared, so a Russian-only form can never dead-end.
local PLURAL_CHAIN = {
  one   = { "_ONE", "_OTHER" },
  few   = { "_FEW", "_MANY", "_OTHER" },
  many  = { "_MANY", "_OTHER" },
  other = { "_OTHER", "_MANY" },
}

-- enUS / deDE / esES / esMX: one for exactly 1, other for everything else.
local function RuleTwoForm(n)
  if n == 1 then return "one" end
  return "other"
end

-- frFR: zero is counted as one ("0 emplacement", not "0 emplacements").
local function RuleFrench(n)
  if n == 0 or n == 1 then return "one" end
  return "other"
end

-- ruRU and the other East Slavic locales. The rule is on the last digit, with
-- the teens (11-14) carved out because they take the many form regardless.
local function RuleRussian(n)
  local mod10, mod100 = n % 10, n % 100
  if mod10 == 1 and mod100 ~= 11 then return "one" end
  if mod10 >= 2 and mod10 <= 4 and (mod100 < 12 or mod100 > 14) then return "few" end
  return "many"
end

local PLURAL_RULE = RuleTwoForm
do
  local locale = (type(GetLocale) == "function" and GetLocale()) or "enUS"
  if locale == "frFR" then
    PLURAL_RULE = RuleFrench
  elseif locale == "ruRU" then
    PLURAL_RULE = RuleRussian
  end
end

-- n -> "one" | "few" | "many" | "other" for the running client's locale.
-- Published so the rule can be exercised without a game client.
function ns.PluralForm(n)
  n = tonumber(n) or 0
  if n < 0 then n = -n end
  return PLURAL_RULE(math.floor(n))
end

-- key, n [, ...] -> the localized counted string, with n as the first format
-- argument. Reads raw, because ns.L's __index answers every key.
function ns.Plural(key, n, ...)
  n = tonumber(n) or 0
  local chain = PLURAL_CHAIN[ns.PluralForm(n)]

  local template
  for i = 1, #chain do
    template = rawget(L, key .. chain[i])
    if type(template) == "string" then break end
    template = nil
  end
  if not template then return tostring(key) end

  local ok, formatted = pcall(string.format, template, n, ...)
  return ok and formatted or template
end

-------------------------------------------------------------
-- English (enUS) -- the complete set. Every block after this one is a partial
-- overlay and inherits whatever it does not mention.
-------------------------------------------------------------
-- Printed to chat, and the one button on a notice dialog.
L["ERR_OPEN_MAILBOX_LOOT"]     = "Walk up to a mailbox and open it first."
L["POPUP_OK"]                  = "OK"

-- Window title, its two tabs, and the collection run's status line.
L["FRAME_TITLE"]               = "Postbox"
L["TAB_COLLECT"]               = "Collect"
L["TAB_SEND"]                  = "Send"
L["STATUS_READY"]              = "Ready"
L["STATUS_REMAINING"]          = "Remaining: %d"
L["STATUS_DONE"]               = "Done"
L["STATUS_STOPPED"]            = "Cut short: the mailbox closed"
L["STATUS_INCOMPLETE"]         = "Incomplete: %d left"
L["STATUS_PARTIAL"]            = "Finished: %d not taken"
-- The whole of the idle status line, and only when it is true: the server has
-- refused a mail's attachments this visit and trying again will not empty it. A
-- healthy idle mailbox shows nothing here, because the collect screen's segments
-- already carry every count there is.
--
-- Shaped like the other status lines -- word, colon, number -- and deliberately
-- number-invariant in every locale, so it needs no plural family.
L["STATUS_STUCK"]              = "Stuck: %d"
L["GRID_TOGGLE_TITLE"]         = "Window grid docking"
-- Every option description below is ONE short sentence saying what the option
-- does. A tooltip that runs to a paragraph is a tooltip nobody finishes.
L["GRID_TOGGLE_DESC"]          = "Other Blizzard windows reserve space for Postbox, and it returns to that spot each time you reopen it."
-- Options menu (cog button)
L["OPTIONS_TITLE"]             = "Postbox options"
L["OPTIONS_COG_TOOLTIP"]       = "Click to open Postbox options."
L["OPT_TAB_COUNTS_TITLE"]      = "Show tab counts"
L["OPT_TAB_COUNTS_DESC"]       = "Put the number of mails on each collect segment, counting anything above 99 as 99+."
L["OPT_COMPACT_ROWS_TITLE"]    = "Compact mail rows"
L["OPT_COMPACT_ROWS_DESC"]     = "Fit more mail on screen by giving each one a single line, with whatever it leaves out in the row's tooltip."
L["OPT_PREVIEW_CLICK_TITLE"]   = "Click opens a mail"
L["OPT_PREVIEW_CLICK_DESC"]    = "Left-click opens a mail and shift-click or right-click collects it; switch it off and the two swap."
-- Window border (only shown when a host UI supplies a border picker — EllesmereUI)
L["OPT_BORDER_TITLE"]          = "Window border"
L["OPT_BORDER_NONE"]           = "None"
L["OPT_BORDER_SIZE_TITLE"]     = "Border size"
L["OPT_BORDER_SIZE_STEP"]      = "Size %d"
L["OPT_APPEARANCE_HEADING"]    = "Appearance"
L["OPT_BG_OPACITY_TITLE"]      = "Background opacity"
L["OPT_BG_OPACITY_STEP"]       = "%d%%"
L["OPT_BG_OPACITY_AUTO"]       = "Match EllesmereUI"
-- Minimap mail icon (Core/MinimapButton.lua)
L["OPT_MINIMAP_HEADING"]       = "Minimap"
L["OPT_MINIMAP_TITLE"]         = "Minimap mail icon"
L["OPT_MINIMAP_DESC"]          = "Replaces the default new-mail icon with Postbox's own on the minimap edge; shift-drag it to move it."
L["OPT_MINIMAP_DESC_EUI"]      = "Restyles EllesmereUI's minimap mail icon with the look you choose below."
L["OPT_MINIMAP_ICON_TITLE"]    = "Icon"
L["OPT_MINIMAP_ICON_POSTBOX"]  = "Envelope"
L["OPT_MINIMAP_ICON_BLIZZARD"] = "Blizzard"
L["OPT_MINIMAP_ICON_CLEAN"]    = "Minimal"
L["OPT_MINIMAP_ICON_MAILBOX"]  = "Mailbox"
L["OPT_MINIMAP_SIZE_TITLE"]    = "Icon size"
L["OPT_MINIMAP_SIZE_STEP"]     = "%d px"
L["OPT_MINIMAP_POS_TITLE"]     = "Position"
L["OPT_MINIMAP_POS_TR"]        = "Top right"
L["OPT_MINIMAP_POS_TL"]        = "Top left"
L["OPT_MINIMAP_POS_BR"]        = "Bottom right"
L["OPT_MINIMAP_POS_BL"]        = "Bottom left"
L["OPT_MINIMAP_POS_CUSTOM"]    = "Custom (shift-drag)"
L["OPT_MINIMAP_ACCENT_TITLE"]  = "Accent colour"
L["OPT_MINIMAP_ACCENT_DESC"]   = "Tints the envelope and its glow with the accent colour, following EllesmereUI's accent when its skin is active."
L["OPT_MINIMAP_GLOW_TITLE"]    = "Glow"
L["OPT_MINIMAP_GLOW_DESC"]     = "A soft glow behind the icon while mail is waiting."
L["OPT_MINIMAP_RESET_POS"]     = "Reset icon position"
L["OPT_MINIMAP_RESET_POS_DESC"] = "Returns the icon to its default spot on the minimap edge."
L["OPT_MINIMAP_EUI_STYLED"]    = "EllesmereUI's minimap is active, so its mail icon carries the style; position and size come from EllesmereUI's own minimap options."
L["MINIMAP_TIP_HINT"]          = "Click for options. Shift-drag to move."
L["MINIMAP_TOGGLE_ON"]         = "Minimap mail icon: on."
L["MINIMAP_TOGGLE_OFF"]        = "Minimap mail icon: off."

-- The six mail categories. Each name does double duty -- it captions a
-- bulk-collect button under the list AND labels the category on a single mail's
-- row -- so it has to be a NAME and never an instruction: "Take sold" would
-- read as nonsense on the one mail it was describing.
L["CAT_ALL"]                   = "All mail"
L["CAT_EXPIRED"]               = "All expired"
L["CAT_SOLD"]                  = "All sold"
L["CAT_CANCELED"]              = "All canceled"
L["CAT_BOUGHT"]                = "All bought"
L["CAT_OTHER"]                 = "Other"

-- The three segments over the list. The first two split the inbox by what a
-- mail still HOLDS, so they are named for that and never for the read flag; the
-- third is their union and applies no filter at all.
--
-- KEEP ALL THREE TO ONE SHORT WORD. Every segment is sized to the longest of the
-- three, counts included, and three of them share the top row with the C.O.D.
-- caption -- so a long translation here costs width three times over and takes
-- it from the caption beside them.
L["VIEW_TO_COLLECT"]           = "Collect"
L["VIEW_DONE"]                 = "Done"
L["VIEW_ALL"]                  = "All"
-- The caption sharing that row. It has to fit beside three segments, so it
-- states the rule and stops.
L["HINT_COD"]                  = "C.O.D. mail is never taken automatically."
-- Taught on the mail row's hover tooltip -- whichever of the two describes the
-- gesture that is NOT the plain click. Keep each to one short line: it sits
-- under whatever text the row had to truncate.
L["HINT_ROW_PREVIEW"]          = "Shift-click or right-click: open without collecting"
L["HINT_ROW_COLLECT"]          = "Shift-click or right-click: collect this mail"
-- Under the client's own "Delete" on the per-row delete control's tooltip. It
-- says the part the glyph cannot: that this is not a hide and not an archive.
L["HINT_ROW_DELETE"]           = "Removes this mail from your mailbox for good."
-- One per view, each true of exactly that view.
L["EMPTY_LIST"]                = "Nothing to collect."
L["EMPTY_LIST_DONE"]           = "Nothing finished yet."
L["EMPTY_LIST_ALL"]            = "Your mailbox is empty."
L["BANNER_EARNED"]             = "Total earned: "
L["BANNER_SPENT"]              = "Total spent: "
-- The same two figures for ONE collection run, said once in chat when it ends.
-- The banner above the list totals what is currently listed and changes as the
-- player switches segments; these describe the sweep that just happened and stay
-- in the log. A side that did not move is left out entirely, so all three forms
-- have to read as complete sentences on their own.
L["MSG_RUN_EARNED"]            = "Earned %s."
L["MSG_RUN_SPENT"]             = "Spent %s."
L["MSG_RUN_EARNED_SPENT"]      = "Earned %s, spent %s."

-- One mail: the chips on its row in the list, and its opened view.
L["SENDER_UNKNOWN"]            = "Unknown"
L["LABEL_GOLD"]                = "Gold: "
-- The amount owed on a C.O.D. mail. Spelled out, because the row has space for
-- it; LABEL_COD_SHORT is the abbreviation, and only stands in where a control
-- has no room at all -- the compose screen's tick box, and a row whose C.O.D.
-- amount is not yet known. The game itself calls this C.O.D. everywhere, so the
-- abbreviation stays as the game writes it.
L["LABEL_COD"]                 = "C.O.D.: "
L["LABEL_COD_SHORT"]           = "C.O.D."
L["STATUS_READ"]               = "Read"
L["STATUS_UNREAD"]             = "Unread"
L["STATUS_RETURNED"]           = "Returned"
L["DETAIL_EXPIRES"]            = "Expires in %.0fd"
L["DAYS_SHORT"]                = "%.0fd"
-- The four halves of an auction invoice. Which pair is shown depends on which
-- side of the sale the mail records.
L["LABEL_SALE"]                = "Sale: "
L["LABEL_DEPOSIT"]             = "Deposit: "
L["LABEL_AH_COMMISSION"]       = "AH fee: "
L["LABEL_PURCHASE"]            = "Purchase: "
L["DETAIL_NO_BODY"]            = "(this mail has no text)"
L["BTN_BACK"]                  = "<< Back"
L["BTN_TAKE_ALL"]              = "Collect"
L["BTN_REPLY"]                 = "Reply"
L["BTN_RETURN"]                = "Return"

-- Counted strings. Read through ns.Plural(key, n) -- never concatenate a
-- suffix. See the plural machinery at the top of this file.
L["COUNT_SLOTS_ONE"]           = "%d slot"
L["COUNT_SLOTS_OTHER"]         = "%d slots"
L["COUNT_MAILS_ONE"]           = "%d mail"
L["COUNT_MAILS_OTHER"]         = "%d mails"
L["COUNT_ITEMS_ONE"]           = "%d item"
L["COUNT_ITEMS_OTHER"]         = "%d items"
L["COUNT_FREE_SLOTS_ONE"]      = "%d free slot"
L["COUNT_FREE_SLOTS_OTHER"]    = "%d free slots"

-- Bulk actions on the list. The bulk delete removes exactly what the Cleared
-- view shows -- read, no money, no attachments -- so it is named for that view
-- and not for the read flag, which would promise something it deliberately does
-- not do.
L["BTN_DELETE_ALL_DONE"]       = "Delete all done"
L["CONFIRM_DELETE_ALL_DONE"]   = "Delete %s? This cannot be undone."
L["CONFIRM_DELETE_MAIL"]       = "Delete this mail? Anything still attached to it will be lost."
L["MSG_INBOX_TRUNCATED"]       = "Showing %d of %d mails - the game only sends this many at once. Collect some and reopen the mailbox to see the rest."
L["REPLY_PREFIX"]              = "Re: %s"

-- Collection safety (server handshake / bag space)
L["MSG_MAIL_TIMEOUT"]          = "The mailbox did not respond in time. That action may not have completed - reopen the mailbox and check."
L["MSG_ITEM_NOT_COLLECTED"]    = "Still in your mailbox: that mail was not fully collected. Nothing was lost."
L["MSG_COLLECT_INCOMPLETE"]    = "Collection stopped: %d mail still in your mailbox. Nothing was lost - reopen the mailbox and try again."
L["MSG_COLLECT_STOPPED_BAGS"]  = "Collection stopped: your bags are full. %d mail still in your mailbox - nothing was lost."
-- Takes the server refused. %s, where present, is the game's own error text.
L["MSG_ITEM_REFUSED"]          = "That item could not be taken and is still in your mailbox - you may already have one, it may be unique, or you may not be able to carry any more of it."
L["MSG_ITEM_REFUSED_REASON"]   = "That item could not be taken and is still in your mailbox. The game said: %s"
L["MSG_MAIL_PARTIAL"]          = "%d item(s) from that mail could not be taken and are still in your mailbox - you may already have one, they may be unique, or you may not be able to carry any more of them."
L["MSG_MAIL_PARTIAL_REASON"]   = "%d item(s) from that mail could not be taken and are still in your mailbox. The game said: %s"
L["MSG_COLLECT_PARTIAL"]       = "Collected %d mail. %d item(s) could not be taken and are still in your mailbox - you may already have one, they may be unique, or you may not be able to carry any more of them."
L["MSG_COLLECT_PARTIAL_REASON"]= "Collected %d mail. %d item(s) could not be taken and are still in your mailbox. The game said: %s"
-- Shown ON a refused mail -- its row marker's tooltip and its detail metadata --
-- for as long as the mailbox stays open. %s is the game's own error text where
-- we could attribute it to this mail, and STUCK_GENERIC where we could not;
-- the generic half lists possibilities and never asserts a cause.
L["STUCK_LINE"]                = "Not collected: %s"
L["STUCK_GENERIC"]             = "you may already have one, it may be unique, or your bags may be full"
L["MSG_BAGS_FULL"]             = "Not enough bag space: %d free slots are needed and you have %d. Nothing was collected."
L["MSG_BAGSPACE_PARTIAL"]      = "Not enough bag space.\n%d mails need %d free slots and you have %d.\nCollect the first %d that fit?"
L["BAGSPACE_CONFIRM_ACCEPT"]   = "Collect what fits"

-- The dialog that asks before any money leaves the player's purse. Its two
-- buttons say what each one does, because "Yes" and "No" over a payment
-- question are the two words people misread.
L["COD_CONFIRM_ACCEPT"]        = "Pay and collect"
L["COD_CONFIRM_CANCEL"]        = "Cancel"
L["COD_CONFIRM_MSG"]           = "Cash on delivery.\nHand over %s to take what is attached?"

-- Composing a mail
L["LABEL_RECIPIENT"]           = "Recipient"
L["LABEL_SUBJECT"]             = "Subject"
L["LABEL_MESSAGE"]             = "Message"
L["LABEL_ATTACHMENTS"]         = "Attachments"
L["LABEL_GOLD_SEND"]           = "Gold:"
-- What the post office charges, which is not what the player is sending.
L["LABEL_SEND_COST"]           = "Cost: "
L["DEFAULT_SUBJECT"]           = "Mail"
L["DEFAULT_BODY"]              = "Enjoy!"
L["BTN_SEND_MAIL"]             = "Send mail"
L["BTN_SEND_MAIL_PENDING"]     = "Sending..."
L["MSG_SEND_TIMEOUT"]          = "No confirmation from the server. Your draft has been kept - check your mailbox before sending it again."
L["MSG_SEND_FAILED"]           = "The mail was not sent. Your draft has been kept."
L["ERR_NO_RECIPIENT"]          = "Enter a recipient."
L["DEFAULT_NO_SUBJECT"]        = "No subject"
-- Two API functions the addon cannot work without. Named, because the only
-- person who can act on either line is one reading a bug report.
L["ERR_SENDMAIL_UNAVAILABLE"]  = "The game's SendMail function is missing."
L["ERR_COD_NO_ATTACHMENT"]     = "C.O.D. needs something attached to charge for."
L["ERR_COD_ZERO_PRICE"]        = "C.O.D. needs an amount above zero."
L["ERR_COD_API_UNAVAILABLE"]   = "The game's SetSendMailCOD function is missing."
-- The tooltip title carries the words behind the abbreviation, since this is
-- the one place with room to join the two.
L["TOOLTIP_COD_TITLE"]         = "Cash on Delivery"
L["TOOLTIP_COD_DESC"]          = "Nothing is handed over until the recipient pays the amount you set."

-- Send guidance (Core/MailRules.lua picks which of these applies).
--
-- Every one of these states a RULE OF THE GAME, never a verdict on the mail in
-- front of the player. Postbox cannot prove a recipient is one of your own
-- characters and cannot read an item's binding reliably, so a line that said
-- "this will fail" would sometimes be wrong about a send that works -- and none
-- of them ever stops a send. Written this way, being wrong costs nothing.
L["SEND_RULE_SELF"]            = "You can't send mail to yourself."
L["SEND_RULE_COD_CAP"]         = "C.O.D. can't be more than %d gold."
L["SEND_RULE_XREALM_WARBAND"]  = "Only Warbound items cross realms. Use the Warband bank for gold and other items."
L["SEND_RULE_XREALM_STRANGER"] = "Only your own characters can receive items or gold on another realm."
L["SEND_RULE_DELIVERY_OWN"]    = "Your other characters receive mail instantly."
L["SEND_RULE_DELIVERY_HOUR"]   = "Mail with attachments usually arrives in about an hour."

-- The recipient picker's categories
--
-- Every one of these names a set of people and must be true of exactly that
-- set. "Recent alliance" was neither: it rendered C_RecentAllies -- people you
-- recently grouped with -- with a faction word in it, so a Horde player read the
-- enemy faction, and the list it labelled also held Battle.net friends and
-- leftovers from the client's autocomplete cache. The Battle.net friends are
-- under Friends now, the leftovers are not offered as a category at all, and
-- what is left is named for what it is.
L["CONTACT_RECENTLY_GROUPED"]  = "Recently grouped"
-- Manually added in the recipient manager. Only appears once the player has
-- un-favourited such a name, since no live source knows about it.
L["CONTACT_MANUAL"]            = "Added by you"
L["CONTACT_GUILD"]             = "Guild"
L["CONTACT_ALTS"]              = "Alts"
L["CONTACT_RECENT"]            = "Recent"
L["CONTACT_FRIENDS"]           = "Friends"
L["CONTACT_FAVORITES"]         = "Favourites"
L["CONTACT_FAV_HINT"]          = "Right-click a name to favourite it."
-- "this list" was written when hiding only emptied the browsable picker and the
-- name went on being suggested as you typed. Hiding now removes it from every
-- offer the addon makes, and the tooltip is read while typing, where there is no
-- visible "list" for the word to point at -- so it names what stops, and where
-- to undo it.
L["CONTACT_HIDE_HINT"]         = "Shift+right-click to hide it from suggestions. Unhide it in the recipient manager."
-- The star button on the Send tab's recipient bar. It opens the list in both
-- states, so the empty case explains itself rather than refusing the click.
-- Phrased so it reads at every count: "1 favourites" would not.
L["CONTACT_FAV_COUNT"]         = "%d in your favourites."
L["CONTACT_FAV_OPEN"]          = "Click to list them."
L["CONTACT_FAV_NONE"]          = "No favourites yet."
L["CONTACT_FAV_MANAGER_HINT"]  = "Or use the star beside a name in the recipient manager."
L["CONTACT_EMPTY_FAVORITES"]   = "No favourites yet.\n\nRight-click any name in these lists to make it a favourite, or use the star in the recipient manager. Favourites are offered first when you address a mail."
-- The last resort, for a category whose emptiness has no better explanation.
L["CONTACT_EMPTY_CATEGORY"]    = "Nothing in this list yet."
-- Why a category is empty, chosen by ContactService.EmptyReason and shown by
-- both recipient windows. The generic line above is true of all of these and
-- useless in every one of them: it told a guildless player their guild list was
-- empty, and told a player waiting on a cold-login roster the same thing.
L["CONTACT_EMPTY_LOADING"]     = "Still reading that list from the server. It fills in on its own."
L["CONTACT_EMPTY_GUILD"]       = "You are not in a guild."
L["CONTACT_EMPTY_FRIENDS"]     = "Nobody is on your friends list, and no Battle.net friend is on a character you could write to."
L["CONTACT_EMPTY_ALTS"]        = "No other characters recorded yet. Log in on one with Postbox installed and it is listed here."
L["CONTACT_EMPTY_RECENT"]      = "You have not sent any mail yet. Everyone you write to is listed here afterwards, newest first."

-- Recipient manager
L["RM_SLASH_HELP"]             = "/postbox recipients - manage which characters appear in the recipient list"
L["RM_NOT_AVAILABLE"]          = "The recipient manager is not available in this build yet."
L["RM_ERR_NAME_EMPTY"]         = "Enter a character name."
L["RM_ERR_NAME_SPACES"]        = "A character name cannot contain spaces."
L["RM_ERR_NAME_LENGTH"]        = "That name is too short or too long."
L["RM_ERR_ALREADY_ADDED"]      = "That recipient has already been added."
L["RM_ERR_NOT_READY"]          = "Postbox is still loading. Try again in a moment."
L["RM_ERR_LIVE_ONLY"]          = "This recipient comes from your guild, friends or account list, so it cannot be deleted. Hide it instead."
-- Recipient manager window
L["RM_TITLE"]                  = "Postbox recipients"
L["RM_SEARCH_PLACEHOLDER"]     = "Search names"
L["RM_SORT_LABEL"]             = "Sort"
-- The sort button's own caption: the label is inside the control, not beside it.
L["RM_SORT_TOGGLE"]            = "Sort: %s"
L["RM_SORT_NAME"]              = "Name"
L["RM_SORT_CATEGORY"]          = "Category"
L["RM_SORT_LEVEL"]             = "Level"
L["RM_SORT_LASTSEEN"]          = "Last played"
-- Sort direction, spelled out per field: an arrow cannot say whether "up" means
-- A-to-Z or level 1 first.
L["RM_SORT_DIR_TIP"]           = "Click to reverse the order. Choosing the sort that is already selected reverses it too."
L["RM_SORT_DIR_NAME_ASC"]      = "A to Z"
L["RM_SORT_DIR_NAME_DESC"]     = "Z to A"
L["RM_SORT_DIR_CATEGORY_ASC"]  = "Alts first, saved names last"
L["RM_SORT_DIR_CATEGORY_DESC"] = "Saved names first, alts last"
L["RM_SORT_DIR_LEVEL_ASC"]     = "Lowest level first"
L["RM_SORT_DIR_LEVEL_DESC"]    = "Highest level first"
L["RM_SORT_DIR_LASTSEEN_ASC"]  = "Least recently played first"
L["RM_SORT_DIR_LASTSEEN_DESC"] = "Most recently played first"
-- Category bar. The four source buckets reuse the CONTACT_* labels the Send tab
-- already uses; only these two are specific to this window.
L["RM_FILTER_ALL"]             = "All"
L["RM_FILTER_HIDDEN"]          = "Hidden"
L["RM_CAT_TIP_COUNT"]          = "%d of %d recipients"
L["RM_CAT_TIP_HINT"]           = "Filters the list below. It combines with the search box, and every bulk action applies to whatever is listed."
L["RM_CAT_TIP_FAV_EMPTY"]      = "Click the star beside a name to make it a favourite. Favourites are offered first when you address a mail."
-- How the current view is named in summaries, tooltips and confirmations.
L["RM_SCOPE_SEARCH"]           = "%s matching \"%s\""
L["RM_SCOPE_SEARCH_ALL"]       = "All, matching \"%s\""
L["RM_SUMMARY"]                = "%d recipients, %d hidden, %d favourites"
L["RM_SUMMARY_FILTERED"]       = "%s: %d of %d recipients, %d hidden, %d favourites"
L["RM_COL_HIDE"]               = "Hide"
L["RM_BTN_DELETE"]             = "Delete"
L["RM_BTN_ADD"]                = "Add recipient"
L["RM_BTN_HIDE_ALL"]           = "Hide all listed"
L["RM_BTN_SHOW_ALL"]           = "Show all listed"
L["RM_BTN_NOTE"]               = "Note"
L["RM_TIP_FAV_ON"]             = "A favourite. Click to remove it from your favourites."
L["RM_TIP_FAV_OFF"]            = "Click to make this a favourite. Favourites are offered first when you address a mail."
L["RM_TIP_HIDE"]               = "Keep this character out of the Send tab's recipient lists. Nothing is deleted - untick to bring it back."
L["RM_TIP_DELETE"]             = "Remove everything Postbox has stored for this character."
L["RM_TIP_NOTE"]               = "A few words of your own about this character. The note shows beside the name in both windows."
-- Right-click means the SAME thing here as it does in the Send tab's contact
-- picker. It used to edit a note in this window and favourite in that one.
L["RM_TIP_ROW_FAV"]            = "Right-click the row to add or remove a favourite."
L["RM_TIP_BULK"]               = "Applies to the %d recipient(s) currently listed (%s). Narrow the list with the categories above and the search box first."
L["RM_TIP_STALE"]              = "No current source offered this name on the last scan. This is only a hint - nothing has been changed."
L["RM_CAT_MANUAL"]             = "Added by you"
L["RM_CAT_SAVED"]              = "Saved"
L["RM_META_LEVEL"]             = "Level %d"
L["RM_META_LAST"]              = "Last played %s"
-- Said only for the player's own characters, where the absence resolves the
-- next time that character is played. A guild member's level can never be read
-- at all, so those rows say nothing about it.
L["RM_META_ALT_UNRECORDED"]    = "Log in to record level and last played"
L["RM_TIP_ALT_UNRECORDED"]     = "Level and last-played are recorded when you log in on one of your own characters. This one has not been played since Postbox started tracking them."
L["RM_META_STALE"]             = "Not in any current list"
L["RM_LAST_TODAY"]             = "today"
L["RM_LAST_YESTERDAY"]         = "yesterday"
L["RM_LAST_DAYS"]              = "%d days ago"
L["RM_LAST_MONTHS"]            = "%d months ago"
L["RM_LAST_YEARS"]             = "%d years ago"
L["RM_EMPTY"]                  = "Nothing to manage yet.\n\nThis window lists every character Postbox can offer as a mail recipient: your alts, your guild, your friends, and anyone you have mailed. Hide the ones you never write to and they stop cluttering the Send tab - nothing is deleted, and you can bring them back here at any time."
L["RM_EMPTY_SEARCH"]           = "No recipient matches \"%s\"."
L["RM_EMPTY_SEARCH_FILTER"]    = "No recipient matching \"%s\" is in %s.\n\nThe search only covers the category you have selected - switch to All to search every recipient."
L["RM_EMPTY_FILTER"]           = "Nothing in %s.\n\nPick another category above, or All to see every recipient."
-- The way out, on its own, so a category that can explain WHY it is empty
-- (CONTACT_EMPTY_*) still ends with the same next step.
L["RM_EMPTY_FILTER_HINT"]      = "Pick another category above, or All to see every recipient."
L["RM_EMPTY_HIDDEN"]           = "Nothing is hidden.\n\nTick Hide beside a name, or narrow the list to a category and use \"Hide all listed\", to keep characters out of the Send tab's recipient lists. Nothing is deleted, and this is where you get them back."
L["RM_EMPTY_FAVOURITES"]       = "No favourites yet.\n\nClick the star beside a name to make it a favourite. Favourites are offered first when you address a mail."
L["RM_ADD_TITLE"]              = "Add a recipient.\nName, or Name-Realm for another realm."
L["RM_ADD_ACCEPT"]             = "Add"
L["RM_ADD_DONE"]               = "%s was added to your favourites."
L["RM_NOTE_TITLE"]             = "Note for %s"
L["RM_NOTE_ACCEPT"]            = "Save"
L["RM_DELETE_CONFIRM"]         = "Delete everything Postbox has stored for %s?\n\nIts hidden/favourite state, its mail history and its saved alt data are removed. If the game offers the name again it will come back."
L["RM_DELETE_ACCEPT"]          = "Delete"
L["RM_DELETE_NOTHING"]         = "Postbox had nothing stored for %s."
-- Both confirmations name the filter as well as the count: "Hide 148
-- recipients?" is a question nobody can answer safely.
L["RM_BULK_HIDE_CONFIRM"]      = "Hide %d recipients?\n\nShowing: %s\n\nThey stay in this window - the Hidden category brings them back at any time. Favourites are never hidden by this."
L["RM_BULK_SHOW_CONFIRM"]      = "Show %d hidden recipients again?\n\nShowing: %s"
L["RM_BULK_ACCEPT"]            = "Apply"
L["RM_BULK_NONE"]              = "Nothing in %s would change."
L["RM_OPT_BUTTON"]             = "Manage recipients (%d)"
L["RM_OPT_BUTTON_DESC"]        = "Choose which characters Postbox offers when you address a mail. Hide the alts you never write to, favourite the ones you do."

-------------------------------------------------------------
-- French (frFR). Zero takes the singular here; see RuleFrench above.
-------------------------------------------------------------
if GetLocale() == "frFR" then
  -- Chat et dialogues
  L["ERR_OPEN_MAILBOX_LOOT"]     = "Approche-toi d'une boite aux lettres et ouvre-la d'abord."
  L["POPUP_OK"]               = "OK"

  -- Fenetre, onglets, ligne d'etat
  L["TAB_COLLECT"]               = "Recuperer"
  L["TAB_SEND"]                  = "Envoyer"
  L["STATUS_READY"]              = "Pret"
  L["STATUS_REMAINING"]          = "Restant: %d"
  L["STATUS_DONE"]               = "Termine"
  L["STATUS_STOPPED"]            = "Interrompu : la boite s'est fermee"
  L["STATUS_INCOMPLETE"]         = "Incomplet: %d restant(s)"
  L["STATUS_PARTIAL"]            = "Fini : %d non pris"
  L["STATUS_STUCK"]              = "Bloques: %d"

  -- Noms de categorie : bouton groupe ET etiquette sur une ligne de courrier.
  L["CAT_ALL"]                   = "Tous les courriers"
  L["CAT_EXPIRED"]               = "Tout expire"
  L["CAT_SOLD"]                  = "Tout vendu"
  L["CAT_CANCELED"]              = "Tout annule"
  L["CAT_BOUGHT"]                = "Tout achete"
  L["CAT_OTHER"]                 = "Autre"

  -- Segments et liste
  L["VIEW_TO_COLLECT"]           = "Recuperer"
  L["VIEW_DONE"]                 = "Termine"
  L["VIEW_ALL"]                  = "Tout"
  L["HINT_COD"]                  = "Un contre-remboursement n'est jamais pris tout seul."
  L["HINT_ROW_PREVIEW"]          = "Maj-clic ou clic droit: ouvrir sans recuperer"
  L["HINT_ROW_COLLECT"]          = "Maj-clic ou clic droit: recuperer ce courrier"
  L["HINT_ROW_DELETE"]           = "Retire definitivement ce courrier de ta boite."
  L["EMPTY_LIST"]                = "Rien a recuperer."
  L["EMPTY_LIST_DONE"]           = "Rien de termine."
  L["EMPTY_LIST_ALL"]            = "Ta boite aux lettres est vide."
  L["BANNER_EARNED"]             = "Total gagne: "
  L["BANNER_SPENT"]              = "Total depense: "
  L["MSG_RUN_EARNED"]            = "Gagne %s."
  L["MSG_RUN_SPENT"]             = "Depense %s."
  L["MSG_RUN_EARNED_SPENT"]      = "Gagne %s, depense %s."

  -- Un courrier : sa ligne et sa vue ouverte
  L["SENDER_UNKNOWN"]            = "Inconnu"
  L["LABEL_GOLD"]                = "Or: "
  L["LABEL_COD"]                 = "C.R.: "
  L["LABEL_COD_SHORT"]           = "C.R."
  L["STATUS_READ"]               = "Lu"
  L["STATUS_UNREAD"]             = "Non lu"
  L["STATUS_RETURNED"]           = "Retourne"
  L["DETAIL_EXPIRES"]            = "Expire dans %.0fj"
  L["DAYS_SHORT"]                = "%.0fj"
  L["LABEL_SALE"]                = "Vente: "
  L["LABEL_DEPOSIT"]             = "Depot: "
  L["LABEL_AH_COMMISSION"]       = "Com. AH: "
  L["LABEL_PURCHASE"]            = "Achat: "
  L["DETAIL_NO_BODY"]            = "(ce courrier ne contient aucun texte)"
  L["BTN_BACK"]                  = "<< Retour"
  L["BTN_TAKE_ALL"]              = "Recuperer"
  L["BTN_REPLY"]                 = "Repondre"
  L["BTN_RETURN"]                = "Renvoyer"

  -- Actions groupees
  L["BTN_DELETE_ALL_DONE"]       = "Supprimer les traites"
  L["CONFIRM_DELETE_ALL_DONE"]   = "Supprimer %s ? Cette action est irreversible."

  -- Comptages. Le francais compte zero comme un singulier.
  L["COUNT_SLOTS_ONE"]           = "%d emplacement"
  L["COUNT_SLOTS_OTHER"]         = "%d emplacements"
  L["COUNT_MAILS_ONE"]           = "%d courrier"
  L["COUNT_MAILS_OTHER"]         = "%d courriers"
  L["COUNT_ITEMS_ONE"]           = "%d objet"
  L["COUNT_ITEMS_OTHER"]         = "%d objets"
  L["COUNT_FREE_SLOTS_ONE"]      = "%d emplacement libre"
  L["COUNT_FREE_SLOTS_OTHER"]    = "%d emplacements libres"

  -- Collection safety
  L["MSG_MAIL_TIMEOUT"]          = "La boite aux lettres n'a pas repondu a temps. L'action n'a peut-etre pas abouti - rouvre la boite pour verifier."
  L["MSG_ITEM_NOT_COLLECTED"]    = "Toujours dans la boite aux lettres: ce courrier n'a pas ete entierement recupere. Rien n'est perdu."
  L["MSG_COLLECT_INCOMPLETE"]    = "Recuperation interrompue: %d courrier(s) toujours dans la boite aux lettres. Rien n'est perdu - rouvre la boite aux lettres et reessaie."
  L["MSG_COLLECT_STOPPED_BAGS"]  = "Recuperation interrompue: tes sacs sont pleins. %d courrier(s) toujours dans la boite aux lettres - rien n'est perdu."
  L["MSG_ITEM_REFUSED"]          = "Cet objet n'a pas pu etre pris et reste dans la boite aux lettres - tu en possedes peut-etre deja un, il est peut-etre unique, ou tu ne peux pas en porter davantage."
  L["MSG_ITEM_REFUSED_REASON"]   = "Cet objet n'a pas pu etre pris et reste dans la boite aux lettres. Le jeu indique: %s"
  L["MSG_MAIL_PARTIAL"]          = "%d objet(s) de ce courrier n'ont pas pu etre pris et restent dans la boite aux lettres - tu en possedes peut-etre deja, ils sont peut-etre uniques, ou tu ne peux pas en porter davantage."
  L["MSG_MAIL_PARTIAL_REASON"]   = "%d objet(s) de ce courrier n'ont pas pu etre pris et restent dans la boite aux lettres. Le jeu indique: %s"
  L["MSG_COLLECT_PARTIAL"]       = "%d courrier(s) recupere(s). %d objet(s) n'ont pas pu etre pris et restent dans la boite aux lettres - tu en possedes peut-etre deja, ils sont peut-etre uniques, ou tu ne peux pas en porter davantage."
  L["MSG_COLLECT_PARTIAL_REASON"]= "%d courrier(s) recupere(s). %d objet(s) n'ont pas pu etre pris et restent dans la boite aux lettres. Le jeu indique: %s"
  L["STUCK_LINE"]                = "Non recupere: %s"
  L["STUCK_GENERIC"]             = "tu en possedes peut-etre deja un, il est peut-etre unique, ou tes sacs sont peut-etre pleins"
  L["MSG_BAGS_FULL"]             = "Espace insuffisant dans les sacs: %d emplacements libres necessaires, tu en as %d. Rien n'a ete recupere."
  L["MSG_BAGSPACE_PARTIAL"]      = "Espace insuffisant dans les sacs.\n%d courriers necessitent %d emplacements libres, tu en as %d.\nRecuperer les %d premiers qui tiennent ?"
  L["BAGSPACE_CONFIRM_ACCEPT"]   = "Recuperer ce qui tient"

  -- Dialogue du contre-remboursement
  L["COD_CONFIRM_ACCEPT"]        = "Payer et recuperer"
  L["COD_CONFIRM_CANCEL"]        = "Annuler"
  L["COD_CONFIRM_MSG"]           = "Contre-remboursement.\nVerser %s pour prendre les pieces attachees ?"

  -- Redaction d'un courrier
  L["LABEL_RECIPIENT"]           = "Destinataire"
  L["LABEL_SUBJECT"]             = "Sujet"
  L["LABEL_MESSAGE"]             = "Message"
  L["LABEL_ATTACHMENTS"]         = "Pieces jointes"
  L["LABEL_GOLD_SEND"]           = "Or:"
  L["LABEL_SEND_COST"]           = "Frais: "
  L["DEFAULT_SUBJECT"]           = "Courrier"
  L["DEFAULT_BODY"]              = "Bonne reception !"
  L["BTN_SEND_MAIL"]             = "Envoyer le courrier"
  L["BTN_SEND_MAIL_PENDING"]     = "Envoi..."
  L["MSG_SEND_TIMEOUT"]          = "Aucune confirmation du serveur. Ton brouillon a ete conserve - verifie ta boite aux lettres avant de renvoyer."
  L["MSG_SEND_FAILED"]           = "Le courrier n'a pas ete envoye. Ton brouillon a ete conserve."
  L["ERR_NO_RECIPIENT"]          = "Indique d'abord a qui l'envoyer."
  L["DEFAULT_NO_SUBJECT"]        = "Pas de sujet"
  L["ERR_SENDMAIL_UNAVAILABLE"]  = "La fonction SendMail du jeu est introuvable."
  L["ERR_COD_NO_ATTACHMENT"]     = "Le contre-remboursement exige une piece a facturer."
  L["ERR_COD_ZERO_PRICE"]        = "Le contre-remboursement exige un montant superieur a zero."
  L["ERR_COD_API_UNAVAILABLE"]   = "La fonction SetSendMailCOD du jeu est introuvable."
  L["TOOLTIP_COD_TITLE"]         = "Contre-Remboursement"
  L["TOOLTIP_COD_DESC"]          = "Rien n'est remis tant que le destinataire n'a pas paye le montant que tu fixes."

  -- Conseils d'envoi
  L["SEND_RULE_SELF"]            = "Tu ne peux pas t'envoyer du courrier a toi-meme."
  L["SEND_RULE_COD_CAP"]         = "Le C.R. ne peut pas depasser %d po."
  L["SEND_RULE_XREALM_WARBAND"]  = "Seuls les objets lies au bataillon changent de royaume. Utilise la banque de bataillon pour l'or et le reste."
  L["SEND_RULE_XREALM_STRANGER"] = "Seuls tes propres personnages peuvent recevoir des objets ou de l'or sur un autre royaume."
  L["SEND_RULE_DELIVERY_OWN"]    = "Tes autres personnages recoivent le courrier instantanement."
  L["SEND_RULE_DELIVERY_HOUR"]   = "Un courrier avec pieces jointes arrive en general au bout d'une heure."

  -- Categories du selecteur de destinataires
  L["CONTACT_RECENTLY_GROUPED"]  = "Groupe recemment"
  L["CONTACT_MANUAL"]            = "Ajoute par toi"
  L["CONTACT_GUILD"]             = "Guilde"
  L["CONTACT_ALTS"]              = "Alts"
  L["CONTACT_RECENT"]            = "Recents"
  L["CONTACT_FRIENDS"]           = "Amis"
  L["CONTACT_FAVORITES"]         = "Favoris"
  L["CONTACT_FAV_HINT"]          = "Clic droit sur un nom pour l'ajouter aux favoris."
  L["CONTACT_HIDE_HINT"]         = "Maj + clic droit pour le retirer des suggestions. Tu le retrouves dans le gestionnaire de destinataires."
  L["CONTACT_FAV_COUNT"]         = "%d dans tes favoris."
  L["CONTACT_FAV_OPEN"]          = "Clique pour les afficher."
  L["CONTACT_FAV_NONE"]          = "Aucun favori pour l'instant."
  L["CONTACT_FAV_MANAGER_HINT"]  = "Ou utilise l'etoile a cote d'un nom dans le gestionnaire de destinataires."
  L["CONTACT_EMPTY_FAVORITES"]   = "Aucun favori pour l'instant.\n\nClic droit sur un nom de ces listes pour en faire un favori, ou utilise l'etoile dans le gestionnaire de destinataires. Les favoris sont proposes en premier lors de l'envoi d'un courrier."
  L["CONTACT_EMPTY_CATEGORY"]    = "Rien dans cette liste pour l'instant."
  L["CONTACT_EMPTY_LOADING"]     = "Lecture de cette liste sur le serveur en cours. Elle se remplira toute seule."
  L["CONTACT_EMPTY_GUILD"]       = "Tu n'es dans aucune guilde."
  L["CONTACT_EMPTY_FRIENDS"]     = "Personne dans ta liste d'amis, et aucun ami Battle.net n'est sur un personnage a qui tu pourrais ecrire."
  L["CONTACT_EMPTY_ALTS"]        = "Aucun autre personnage enregistre pour l'instant. Connecte-toi sur l'un d'eux avec Postbox installe et il apparaitra ici."
  L["CONTACT_EMPTY_RECENT"]      = "Tu n'as encore envoye aucun courrier. Tous ceux a qui tu ecris sont listes ici ensuite, du plus recent au plus ancien."

  -- Gestionnaire de destinataires
  L["RM_SLASH_HELP"]             = "/postbox recipients - gerer les personnages proposes comme destinataires"
  L["RM_NOT_AVAILABLE"]          = "Le gestionnaire de destinataires n'est pas encore disponible dans cette version."
  L["RM_ERR_NAME_EMPTY"]         = "Saisis un nom de personnage."
  L["RM_ERR_NAME_SPACES"]        = "Un nom de personnage ne peut pas contenir d'espaces."
  L["RM_ERR_NAME_LENGTH"]        = "Ce nom est trop court ou trop long."
  L["RM_ERR_ALREADY_ADDED"]      = "Ce destinataire a deja ete ajoute."
  L["RM_ERR_NOT_READY"]          = "Postbox est encore en cours de chargement. Reessaie dans un instant."
  L["RM_ERR_LIVE_ONLY"]          = "Ce destinataire vient de ta guilde, de tes amis ou de la liste du compte : il ne peut pas etre supprime. Masque-le plutot."
  L["RM_TITLE"]                  = "Destinataires Postbox"
  L["RM_SEARCH_PLACEHOLDER"]     = "Rechercher un nom"
  L["RM_SORT_LABEL"]             = "Tri"
  L["RM_SORT_TOGGLE"]            = "Tri : %s"
  L["RM_SORT_NAME"]              = "Nom"
  L["RM_SORT_CATEGORY"]          = "Categorie"
  L["RM_SORT_LEVEL"]             = "Niveau"
  L["RM_SORT_LASTSEEN"]          = "Derniere connexion"
  L["RM_SORT_DIR_TIP"]           = "Clique pour inverser l'ordre. Rechoisir le tri deja selectionne l'inverse aussi."
  L["RM_SORT_DIR_NAME_ASC"]      = "De A a Z"
  L["RM_SORT_DIR_NAME_DESC"]     = "De Z a A"
  L["RM_SORT_DIR_CATEGORY_ASC"]  = "Alts d'abord, noms enregistres a la fin"
  L["RM_SORT_DIR_CATEGORY_DESC"] = "Noms enregistres d'abord, alts a la fin"
  L["RM_SORT_DIR_LEVEL_ASC"]     = "Niveau le plus bas d'abord"
  L["RM_SORT_DIR_LEVEL_DESC"]    = "Niveau le plus haut d'abord"
  L["RM_SORT_DIR_LASTSEEN_ASC"]  = "Connexion la plus ancienne d'abord"
  L["RM_SORT_DIR_LASTSEEN_DESC"] = "Connexion la plus recente d'abord"
  L["RM_FILTER_ALL"]             = "Tous"
  L["RM_FILTER_HIDDEN"]          = "Masques"
  L["RM_CAT_TIP_COUNT"]          = "%d destinataires sur %d"
  L["RM_CAT_TIP_HINT"]           = "Filtre la liste ci-dessous. Se combine avec la recherche, et toute action groupee s'applique a ce qui est affiche."
  L["RM_CAT_TIP_FAV_EMPTY"]      = "Clique sur l'etoile a cote d'un nom pour en faire un favori. Les favoris sont proposes en premier lors de l'envoi d'un courrier."
  L["RM_SCOPE_SEARCH"]           = "%s contenant \"%s\""
  L["RM_SCOPE_SEARCH_ALL"]       = "Tous, contenant \"%s\""
  L["RM_SUMMARY"]                = "%d destinataires, %d masques, %d favoris"
  L["RM_SUMMARY_FILTERED"]       = "%s : %d sur %d destinataires, %d masques, %d favoris"
  L["RM_COL_HIDE"]               = "Masquer"
  L["RM_BTN_DELETE"]             = "Supprimer"
  L["RM_BTN_ADD"]                = "Ajouter un destinataire"
  L["RM_BTN_HIDE_ALL"]           = "Masquer la liste"
  L["RM_BTN_SHOW_ALL"]           = "Afficher la liste"
  L["RM_BTN_NOTE"]               = "Note"
  L["RM_TIP_FAV_ON"]             = "Favori. Clique pour le retirer de tes favoris."
  L["RM_TIP_FAV_OFF"]            = "Clique pour en faire un favori. Les favoris sont proposes en premier lors de l'envoi."
  L["RM_TIP_HIDE"]               = "Retire ce personnage des listes de destinataires de l'onglet Envoyer. Rien n'est supprime - decoche pour le faire revenir."
  L["RM_TIP_DELETE"]             = "Supprime tout ce que Postbox a enregistre pour ce personnage."
  L["RM_TIP_NOTE"]               = "Quelques mots a toi sur ce personnage. La note s'affiche a cote du nom dans les deux fenetres."
  L["RM_TIP_ROW_FAV"]            = "Clic droit sur la ligne pour ajouter ou retirer un favori."
  L["RM_TIP_BULK"]               = "S'applique aux %d destinataire(s) actuellement affiches (%s). Affine d'abord la liste avec les categories ci-dessus et la recherche."
  L["RM_TIP_STALE"]              = "Aucune source actuelle n'a propose ce nom lors du dernier balayage. Ce n'est qu'une indication - rien n'a ete modifie."
  L["RM_CAT_MANUAL"]             = "Ajoute par toi"
  L["RM_CAT_SAVED"]              = "Enregistre"
  L["RM_META_LEVEL"]             = "Niveau %d"
  L["RM_META_LAST"]              = "Derniere connexion %s"
  L["RM_META_ALT_UNRECORDED"]    = "Connecte-toi pour enregistrer niveau et connexion"
  L["RM_TIP_ALT_UNRECORDED"]     = "Le niveau et la derniere connexion sont enregistres quand tu te connectes sur un de tes propres personnages. Celui-ci n'a pas ete joue depuis que Postbox a commence a les suivre."
  L["RM_META_STALE"]             = "Dans aucune liste actuelle"
  L["RM_LAST_TODAY"]             = "aujourd'hui"
  L["RM_LAST_YESTERDAY"]         = "hier"
  L["RM_LAST_DAYS"]              = "il y a %d jours"
  L["RM_LAST_MONTHS"]            = "il y a %d mois"
  L["RM_LAST_YEARS"]             = "il y a %d ans"
  L["RM_EMPTY"]                  = "Rien a gerer pour l'instant.\n\nCette fenetre liste tous les personnages que Postbox peut proposer comme destinataires : tes alts, ta guilde, tes amis et tous ceux a qui tu as ecrit. Masque ceux a qui tu n'ecris jamais et ils cessent d'encombrer l'onglet Envoyer - rien n'est supprime, et tu peux les faire revenir ici a tout moment."
  L["RM_EMPTY_SEARCH"]           = "Aucun destinataire ne correspond a \"%s\"."
  L["RM_EMPTY_SEARCH_FILTER"]    = "Aucun destinataire correspondant a \"%s\" dans %s.\n\nLa recherche ne couvre que la categorie selectionnee - passe a Tous pour chercher parmi tous les destinataires."
  L["RM_EMPTY_FILTER"]           = "Rien dans %s.\n\nChoisis une autre categorie ci-dessus, ou Tous pour voir tous les destinataires."
  L["RM_EMPTY_FILTER_HINT"]      = "Choisis une autre categorie ci-dessus, ou Tous pour voir tous les destinataires."
  L["RM_EMPTY_HIDDEN"]           = "Rien n'est masque.\n\nCoche Masquer a cote d'un nom, ou filtre la liste par categorie puis utilise \"Masquer la liste\", pour garder des personnages hors des listes de destinataires de l'onglet Envoyer. Rien n'est supprime, et c'est ici que tu les recuperes."
  L["RM_EMPTY_FAVOURITES"]       = "Aucun favori pour l'instant.\n\nClique sur l'etoile a cote d'un nom pour en faire un favori. Les favoris sont proposes en premier lors de l'envoi d'un courrier."
  L["RM_ADD_TITLE"]              = "Ajouter un destinataire.\nNom, ou Nom-Royaume pour un autre royaume."
  L["RM_ADD_ACCEPT"]             = "Ajouter"
  L["RM_ADD_DONE"]               = "%s a ete ajoute a tes favoris."
  L["RM_NOTE_TITLE"]             = "Note pour %s"
  L["RM_NOTE_ACCEPT"]            = "Enregistrer"
  L["RM_DELETE_CONFIRM"]         = "Supprimer tout ce que Postbox a enregistre pour %s ?\n\nSon etat masque/favori, son historique de courrier et ses donnees d'alt enregistrees sont effaces. Si le jeu propose de nouveau ce nom, il reviendra."
  L["RM_DELETE_ACCEPT"]          = "Supprimer"
  L["RM_DELETE_NOTHING"]         = "Postbox n'avait rien enregistre pour %s."
  L["RM_BULK_HIDE_CONFIRM"]      = "Masquer %d destinataires ?\n\nAffichage : %s\n\nIls restent dans cette fenetre - la categorie Masques les fait revenir a tout moment. Les favoris ne sont jamais masques par cette action."
  L["RM_BULK_SHOW_CONFIRM"]      = "Reafficher %d destinataires masques ?\n\nAffichage : %s"
  L["RM_BULK_ACCEPT"]            = "Appliquer"
  L["RM_BULK_NONE"]              = "Rien ne changerait dans %s."
  L["RM_OPT_BUTTON"]             = "Gerer les destinataires (%d)"
  L["RM_OPT_BUTTON_DESC"]        = "Choisis les personnages que Postbox propose lors de l'envoi d'un courrier. Masque les alts a qui tu n'ecris jamais, mets en favori ceux a qui tu ecris."

  -- Options
  L["OPT_TAB_COUNTS_TITLE"]      = "Afficher les compteurs"
  L["OPT_TAB_COUNTS_DESC"]       = "Indique le nombre de courriers sur chaque segment, tout ce qui depasse 99 comptant comme 99+."
  L["OPT_COMPACT_ROWS_TITLE"]    = "Lignes de courrier compactes"
  L["OPT_COMPACT_ROWS_DESC"]     = "Affiche plus de courriers a l'ecran en donnant une seule ligne a chacun, ce qu'une ligne omet passant dans son infobulle."
  L["OPT_PREVIEW_CLICK_TITLE"]   = "Le clic ouvre le courrier"
  L["OPT_PREVIEW_CLICK_DESC"]    = "Le clic gauche ouvre le courrier et Maj-clic ou clic droit le recupere ; desactive, les deux s'echangent."
  L["OPT_MINIMAP_HEADING"]       = "Minicarte"
  L["OPT_MINIMAP_TITLE"]         = "Icone de courrier sur la minicarte"
  L["OPT_MINIMAP_DESC"]          = "Remplace l'icone de nouveau courrier par celle de Postbox sur le bord de la minicarte ; Maj-glisse pour la deplacer."
  L["OPT_MINIMAP_DESC_EUI"]      = "Rhabille l'icone de courrier de la minicarte d'EllesmereUI avec le style choisi ci-dessous."
  L["OPT_MINIMAP_ICON_TITLE"]    = "Icone"
  L["OPT_MINIMAP_ICON_POSTBOX"]  = "Enveloppe"
  L["OPT_MINIMAP_ICON_BLIZZARD"] = "Blizzard"
  L["OPT_MINIMAP_ICON_CLEAN"]    = "Minimale"
  L["OPT_MINIMAP_ICON_MAILBOX"]  = "Boite aux lettres"
  L["OPT_MINIMAP_SIZE_TITLE"]    = "Taille de l'icone"
  L["OPT_MINIMAP_SIZE_STEP"]     = "%d px"
  L["OPT_MINIMAP_POS_TITLE"]     = "Position"
  L["OPT_MINIMAP_POS_TR"]        = "En haut a droite"
  L["OPT_MINIMAP_POS_TL"]        = "En haut a gauche"
  L["OPT_MINIMAP_POS_BR"]        = "En bas a droite"
  L["OPT_MINIMAP_POS_BL"]        = "En bas a gauche"
  L["OPT_MINIMAP_POS_CUSTOM"]    = "Personnalisee (Maj-glisser)"
  L["OPT_MINIMAP_ACCENT_TITLE"]  = "Couleur d'accent"
  L["OPT_MINIMAP_ACCENT_DESC"]   = "Teinte l'enveloppe et son halo avec la couleur d'accent, en suivant celle d'EllesmereUI quand son habillage est actif."
  L["OPT_MINIMAP_GLOW_TITLE"]    = "Halo"
  L["OPT_MINIMAP_GLOW_DESC"]     = "Un halo discret derriere l'icone tant que du courrier attend."
  L["OPT_MINIMAP_RESET_POS"]     = "Reinitialiser la position de l'icone"
  L["OPT_MINIMAP_RESET_POS_DESC"] = "Replace l'icone a son emplacement par defaut sur le bord de la minicarte."
  L["OPT_MINIMAP_EUI_STYLED"]    = "La minicarte d'EllesmereUI est active : son icone de courrier porte le style ; la position et la taille viennent des options de minicarte d'EllesmereUI."
  L["MINIMAP_TIP_HINT"]          = "Clic : options. Maj-glisser : deplacer."
  L["MINIMAP_TOGGLE_ON"]         = "Icone de courrier sur la minicarte : activee."
  L["MINIMAP_TOGGLE_OFF"]        = "Icone de courrier sur la minicarte : desactivee."
end

-------------------------------------------------------------
-- German (deDE). Compounds run long -- every caption below was chosen to fit
-- the control it sits in, not to be the most literal translation.
-------------------------------------------------------------
if GetLocale() == "deDE" then
  L["ERR_OPEN_MAILBOX_LOOT"]     = "Geh zu einem Briefkasten und oeffne ihn zuerst."
  L["POPUP_OK"]                  = "Schliessen"

  L["TAB_COLLECT"]               = "Abholen"
  L["TAB_SEND"]                  = "Senden"
  L["STATUS_READY"]              = "Bereit"
  L["STATUS_REMAINING"]          = "Verbleibend: %d"
  L["STATUS_DONE"]               = "Fertig"
  L["STATUS_STOPPED"]            = "Abgebrochen: der Briefkasten ging zu"
  L["STATUS_INCOMPLETE"]         = "Unvollstaendig: %d uebrig"
  L["STATUS_PARTIAL"]            = "Beendet: %d nicht genommen"
  L["STATUS_STUCK"]              = "Steckt fest: %d"

  -- Kategorienamen: Sammelknopf UND Etikett auf einer einzelnen Postzeile.
  L["CAT_ALL"]                   = "Alle Post"
  L["CAT_EXPIRED"]               = "Alle abgelaufen"
  L["CAT_SOLD"]                  = "Alle verkauft"
  L["CAT_CANCELED"]              = "Alle abgebrochen"
  L["CAT_BOUGHT"]                = "Alle gekauft"
  L["CAT_OTHER"]                 = "Sonstige"

  -- Drei Segmente teilen sich die Zeile mit dem Nachnahme-Hinweis, also bleibt
  -- jedes bei einem kurzen Wort.
  L["VIEW_TO_COLLECT"]           = "Abholen"
  L["VIEW_DONE"]                 = "Erledigt"
  L["VIEW_ALL"]                  = "Alle"
  L["HINT_COD"]                  = "Nachnahme wird nie von allein genommen."
  L["HINT_ROW_PREVIEW"]          = "Umschalt- oder Rechtsklick: oeffnen ohne Abholen"
  L["HINT_ROW_COLLECT"]          = "Umschalt- oder Rechtsklick: diese Post abholen"
  L["HINT_ROW_DELETE"]           = "Entfernt diese Post endgueltig aus dem Briefkasten."
  L["EMPTY_LIST"]                = "Nichts abzuholen."
  L["EMPTY_LIST_DONE"]           = "Noch nichts erledigt."
  L["EMPTY_LIST_ALL"]            = "Dein Briefkasten ist leer."
  L["BANNER_EARNED"]             = "Einnahmen: "
  L["BANNER_SPENT"]              = "Ausgaben: "
  L["MSG_RUN_EARNED"]            = "Eingenommen: %s."
  L["MSG_RUN_SPENT"]             = "Ausgegeben: %s."
  L["MSG_RUN_EARNED_SPENT"]      = "Eingenommen: %s, ausgegeben: %s."

  L["SENDER_UNKNOWN"]            = "Unbekannt"
  L["LABEL_GOLD"]                = "Gold: "
  L["LABEL_COD"]                 = "NN: "
  L["LABEL_COD_SHORT"]           = "NN"
  L["STATUS_READ"]               = "Gelesen"
  L["STATUS_UNREAD"]             = "Ungelesen"
  L["STATUS_RETURNED"]           = "Zurueckgeschickt"
  L["DETAIL_EXPIRES"]            = "Noch %.0fT"
  L["DAYS_SHORT"]                = "%.0fT"
  L["LABEL_SALE"]                = "Verkauf: "
  L["LABEL_DEPOSIT"]             = "Kaution: "
  L["LABEL_AH_COMMISSION"]       = "AH-Gebuehr: "
  L["LABEL_PURCHASE"]            = "Kauf: "
  L["DETAIL_NO_BODY"]            = "(diese Post enthaelt keinen Text)"
  L["BTN_BACK"]                  = "<< Zurueck"
  L["BTN_TAKE_ALL"]              = "Abholen"
  L["BTN_REPLY"]                 = "Antworten"
  L["BTN_RETURN"]                = "Zurueckschicken"

  -- Sammelaktionen
  L["BTN_DELETE_ALL_DONE"]       = "Alle erledigten loeschen"
  L["CONFIRM_DELETE_ALL_DONE"]   = "%s loeschen? Das laesst sich nicht rueckgaengig machen."

  -- Zaehlungen
  L["COUNT_SLOTS_ONE"]           = "%d Platz"
  L["COUNT_SLOTS_OTHER"]         = "%d Plaetze"
  L["COUNT_MAILS_ONE"]           = "%d Nachricht"
  L["COUNT_MAILS_OTHER"]         = "%d Nachrichten"
  L["COUNT_ITEMS_ONE"]           = "%d Gegenstand"
  L["COUNT_ITEMS_OTHER"]         = "%d Gegenstaende"
  L["COUNT_FREE_SLOTS_ONE"]      = "%d freier Platz"
  L["COUNT_FREE_SLOTS_OTHER"]    = "%d freie Plaetze"

  -- Collection safety
  L["MSG_MAIL_TIMEOUT"]          = "Der Briefkasten hat nicht rechtzeitig geantwortet. Die Aktion wurde moeglicherweise nicht abgeschlossen - oeffne den Briefkasten erneut und pruefe es."
  L["MSG_ITEM_NOT_COLLECTED"]    = "Noch im Briefkasten: Diese Post wurde nicht vollstaendig abgeholt. Es ging nichts verloren."
  L["MSG_COLLECT_INCOMPLETE"]    = "Abholen gestoppt: %d Post noch im Briefkasten. Es ging nichts verloren - oeffne den Briefkasten erneut und versuche es noch einmal."
  L["MSG_COLLECT_STOPPED_BAGS"]  = "Abholen gestoppt: Deine Taschen sind voll. %d Post noch im Briefkasten - es ging nichts verloren."
  L["MSG_ITEM_REFUSED"]          = "Dieser Gegenstand konnte nicht genommen werden und liegt weiter im Briefkasten - vielleicht hast du bereits einen, er ist einzigartig, oder du kannst nicht mehr davon tragen."
  L["MSG_ITEM_REFUSED_REASON"]   = "Dieser Gegenstand konnte nicht genommen werden und liegt weiter im Briefkasten. Das Spiel sagt: %s"
  L["MSG_MAIL_PARTIAL"]          = "%d Gegenstand/Gegenstaende aus dieser Post konnten nicht genommen werden und liegen weiter im Briefkasten - vielleicht hast du sie bereits, sie sind einzigartig, oder du kannst nicht mehr davon tragen."
  L["MSG_MAIL_PARTIAL_REASON"]   = "%d Gegenstand/Gegenstaende aus dieser Post konnten nicht genommen werden und liegen weiter im Briefkasten. Das Spiel sagt: %s"
  L["MSG_COLLECT_PARTIAL"]       = "%d Post abgeholt. %d Gegenstand/Gegenstaende konnten nicht genommen werden und liegen weiter im Briefkasten - vielleicht hast du sie bereits, sie sind einzigartig, oder du kannst nicht mehr davon tragen."
  L["MSG_COLLECT_PARTIAL_REASON"]= "%d Post abgeholt. %d Gegenstand/Gegenstaende konnten nicht genommen werden und liegen weiter im Briefkasten. Das Spiel sagt: %s"
  L["STUCK_LINE"]                = "Nicht abgeholt: %s"
  L["STUCK_GENERIC"]             = "vielleicht hast du bereits einen, er ist einzigartig, oder deine Taschen sind voll"
  L["MSG_BAGS_FULL"]             = "Nicht genug Taschenplatz: %d freie Plaetze werden benoetigt, du hast %d. Es wurde nichts abgeholt."
  L["MSG_BAGSPACE_PARTIAL"]      = "Nicht genug Taschenplatz.\n%d Postsendungen benoetigen %d freie Plaetze, du hast %d.\nDie ersten %d abholen, die hineinpassen?"
  L["BAGSPACE_CONFIRM_ACCEPT"]   = "Abholen, was passt"

  L["COD_CONFIRM_ACCEPT"]        = "Bezahlen und abholen"
  L["COD_CONFIRM_CANCEL"]        = "Abbrechen"
  L["COD_CONFIRM_MSG"]           = "Nachnahme.\n%s hergeben, um das Beigelegte zu nehmen?"

  L["LABEL_RECIPIENT"]           = "Empfaenger"
  L["LABEL_SUBJECT"]             = "Betreff"
  L["LABEL_MESSAGE"]             = "Nachricht"
  L["LABEL_ATTACHMENTS"]         = "Anlagen"
  L["LABEL_GOLD_SEND"]           = "Gold:"
  L["LABEL_SEND_COST"]           = "Kosten: "
  L["DEFAULT_SUBJECT"]           = "Post"
  L["DEFAULT_BODY"]              = "Viel Spass!"
  L["BTN_SEND_MAIL"]             = "Post senden"
  L["BTN_SEND_MAIL_PENDING"]     = "Senden..."
  L["MSG_SEND_TIMEOUT"]          = "Keine Bestaetigung vom Server. Dein Entwurf wurde behalten - pruefe deinen Briefkasten, bevor du erneut sendest."
  L["MSG_SEND_FAILED"]           = "Die Post wurde nicht gesendet. Dein Entwurf wurde behalten."
  L["ERR_NO_RECIPIENT"]          = "Gib zuerst an, an wen es gehen soll."
  L["DEFAULT_NO_SUBJECT"]        = "Kein Betreff"
  L["ERR_SENDMAIL_UNAVAILABLE"]  = "Die Spielfunktion SendMail fehlt."
  L["ERR_COD_NO_ATTACHMENT"]     = "Nachnahme braucht etwas Beigelegtes zum Berechnen."
  L["ERR_COD_ZERO_PRICE"]        = "Nachnahme braucht einen Betrag ueber null."
  L["ERR_COD_API_UNAVAILABLE"]   = "Die Spielfunktion SetSendMailCOD fehlt."
  L["TOOLTIP_COD_TITLE"]         = "Nachnahme"
  L["TOOLTIP_COD_DESC"]          = "Es wird nichts herausgegeben, bis der Empfaenger den von dir gesetzten Betrag zahlt."

  -- Versandhinweise
  L["SEND_RULE_SELF"]            = "Du kannst dir selbst keine Post schicken."
  L["SEND_RULE_COD_CAP"]         = "Nachnahme darf hoechstens %d Gold betragen."
  L["SEND_RULE_XREALM_WARBAND"]  = "Nur kriegsmeutengebundene Gegenstaende wechseln den Realm. Fuer Gold und alles andere: die Kriegsmeutenbank."
  L["SEND_RULE_XREALM_STRANGER"] = "Nur deine eigenen Charaktere koennen auf einem anderen Realm Gegenstaende oder Gold empfangen."
  L["SEND_RULE_DELIVERY_OWN"]    = "Deine anderen Charaktere erhalten Post sofort."
  L["SEND_RULE_DELIVERY_HOUR"]   = "Post mit Anlagen kommt meist nach etwa einer Stunde an."

  L["CONTACT_RECENTLY_GROUPED"]  = "Kuerzlich gruppiert"
  L["CONTACT_MANUAL"]            = "Von dir hinzugefuegt"
  L["CONTACT_GUILD"]             = "Gilde"
  L["CONTACT_ALTS"]              = "Alts"
  L["CONTACT_RECENT"]            = "Letzte"
  L["CONTACT_FRIENDS"]           = "Freunde"
  -- Both lines of the same tooltip, so it cannot come out half German.
  L["CONTACT_FAV_HINT"]          = "Rechtsklick auf einen Namen macht ihn zum Favoriten."
  L["CONTACT_HIDE_HINT"]         = "Umschalt + Rechtsklick blendet ihn aus den Vorschlaegen aus. Zurueckholen in der Empfaengerverwaltung."
  -- The Send tab's category bar says All in words, from the same key the
  -- recipient manager's filter row uses.
  L["RM_FILTER_ALL"]             = "Alle"
  L["CONTACT_EMPTY_LOADING"]     = "Diese Liste wird noch vom Server gelesen. Sie fuellt sich von selbst."
  L["CONTACT_EMPTY_GUILD"]       = "Du bist in keiner Gilde."
  L["CONTACT_EMPTY_FRIENDS"]     = "Niemand auf deiner Freundesliste, und kein Battle.net-Freund ist auf einem Charakter, dem du schreiben koenntest."
  L["CONTACT_EMPTY_ALTS"]        = "Noch keine weiteren Charaktere erfasst. Melde dich mit installiertem Postbox auf einem an, dann erscheint er hier."
  L["CONTACT_EMPTY_RECENT"]      = "Du hast noch keine Post verschickt. Jeder, dem du schreibst, steht danach hier - der neueste zuerst."

  -- Empfaengerverwaltung
  L["RM_BTN_NOTE"]               = "Notiz"
  L["RM_TIP_NOTE"]               = "Ein paar eigene Worte zu diesem Charakter. Die Notiz steht in beiden Fenstern neben dem Namen."
  L["RM_TIP_ROW_FAV"]            = "Rechtsklick auf die Zeile, um einen Favoriten hinzuzufuegen oder zu entfernen."
  L["RM_EMPTY_FILTER_HINT"]      = "Waehle oben eine andere Kategorie, oder Alle, um jeden Empfaenger zu sehen."

  -- Optionen
  L["OPT_TAB_COUNTS_TITLE"]      = "Anzahl auf den Segmenten"
  L["OPT_TAB_COUNTS_DESC"]       = "Zeigt die Anzahl der Briefe auf jedem Segment, alles ueber 99 als 99+."
  L["OPT_COMPACT_ROWS_TITLE"]    = "Kompakte Postzeilen"
  L["OPT_COMPACT_ROWS_DESC"]     = "Zeigt mehr Post auf einmal, indem jeder Brief nur eine Zeile bekommt und der Rest in den Tooltip wandert."
  L["OPT_PREVIEW_CLICK_TITLE"]   = "Klick oeffnet die Post"
  L["OPT_PREVIEW_CLICK_DESC"]    = "Linksklick oeffnet die Post und Umschalt- oder Rechtsklick holt sie ab; ausgeschaltet tauschen die beiden."
  L["OPT_MINIMAP_HEADING"]       = "Minikarte"
  L["OPT_MINIMAP_TITLE"]         = "Postsymbol an der Minikarte"
  L["OPT_MINIMAP_DESC"]          = "Ersetzt das Standardsymbol fuer neue Post durch Postbox' eigenes am Rand der Minikarte; mit Umschalt-Ziehen verschiebst du es."
  L["OPT_MINIMAP_DESC_EUI"]      = "Gestaltet das Postsymbol der EllesmereUI-Minikarte mit dem unten gewaehlten Stil."
  L["OPT_MINIMAP_ICON_TITLE"]    = "Symbol"
  L["OPT_MINIMAP_ICON_POSTBOX"]  = "Umschlag"
  L["OPT_MINIMAP_ICON_BLIZZARD"] = "Blizzard"
  L["OPT_MINIMAP_ICON_CLEAN"]    = "Minimal"
  L["OPT_MINIMAP_ICON_MAILBOX"]  = "Briefkasten"
  L["OPT_MINIMAP_SIZE_TITLE"]    = "Symbolgroesse"
  L["OPT_MINIMAP_SIZE_STEP"]     = "%d px"
  L["OPT_MINIMAP_POS_TITLE"]     = "Position"
  L["OPT_MINIMAP_POS_TR"]        = "Oben rechts"
  L["OPT_MINIMAP_POS_TL"]        = "Oben links"
  L["OPT_MINIMAP_POS_BR"]        = "Unten rechts"
  L["OPT_MINIMAP_POS_BL"]        = "Unten links"
  L["OPT_MINIMAP_POS_CUSTOM"]    = "Frei (Umschalt-Ziehen)"
  L["OPT_MINIMAP_ACCENT_TITLE"]  = "Akzentfarbe"
  L["OPT_MINIMAP_ACCENT_DESC"]   = "Faerbt Umschlag und Leuchten in der Akzentfarbe, bei aktivem EllesmereUI-Skin in dessen Akzent."
  L["OPT_MINIMAP_GLOW_TITLE"]    = "Leuchten"
  L["OPT_MINIMAP_GLOW_DESC"]     = "Ein sanftes Leuchten hinter dem Symbol, solange Post wartet."
  L["OPT_MINIMAP_RESET_POS"]     = "Symbolposition zuruecksetzen"
  L["OPT_MINIMAP_RESET_POS_DESC"] = "Setzt das Symbol auf seinen Standardplatz am Minikartenrand zurueck."
  L["OPT_MINIMAP_EUI_STYLED"]    = "Die EllesmereUI-Minikarte ist aktiv, ihr Postsymbol traegt den Stil; Position und Groesse kommen aus den Minikarten-Optionen von EllesmereUI."
  L["MINIMAP_TIP_HINT"]          = "Klick: Optionen. Umschalt-Ziehen: verschieben."
  L["MINIMAP_TOGGLE_ON"]         = "Postsymbol an der Minikarte: an."
  L["MINIMAP_TOGGLE_OFF"]        = "Postsymbol an der Minikarte: aus."
end

-------------------------------------------------------------
-- Spanish (esES and esMX both take this block).
-------------------------------------------------------------
local esLocale = GetLocale()
if esLocale == "esES" or esLocale == "esMX" then
  L["ERR_OPEN_MAILBOX_LOOT"]     = "Acercate a un buzon y abrelo primero."
  L["POPUP_OK"]                  = "Cerrar"

  L["TAB_COLLECT"]               = "Recoger"
  L["TAB_SEND"]                  = "Enviar"
  L["STATUS_READY"]              = "Listo"
  L["STATUS_REMAINING"]          = "Restante: %d"
  L["STATUS_DONE"]               = "Hecho"
  L["STATUS_STOPPED"]            = "Cortado: el buzon se cerro"
  L["STATUS_INCOMPLETE"]         = "Incompleto: quedan %d"
  L["STATUS_PARTIAL"]            = "Terminado: %d sin recoger"
  L["STATUS_STUCK"]              = "Atascados: %d"

  -- Nombres de categoria: boton en bloque Y etiqueta en la fila de un correo.
  L["CAT_ALL"]                   = "Todo el correo"
  L["CAT_EXPIRED"]               = "Todo expirado"
  L["CAT_SOLD"]                  = "Todo vendido"
  L["CAT_CANCELED"]              = "Todo cancelado"
  L["CAT_BOUGHT"]                = "Todo comprado"
  L["CAT_OTHER"]                 = "Otro"

  L["VIEW_TO_COLLECT"]           = "Recoger"
  L["VIEW_DONE"]                 = "Hecho"
  L["VIEW_ALL"]                  = "Todo"
  L["HINT_COD"]                  = "El contra reembolso nunca se recoge solo."
  L["HINT_ROW_PREVIEW"]          = "Mayus-clic o clic derecho: abrir sin recoger"
  L["HINT_ROW_COLLECT"]          = "Mayus-clic o clic derecho: recoger este correo"
  L["HINT_ROW_DELETE"]           = "Quita este correo de tu buzon para siempre."
  L["EMPTY_LIST"]                = "Nada por recoger."
  L["EMPTY_LIST_DONE"]           = "Nada vaciado todavia."
  L["EMPTY_LIST_ALL"]            = "Tu buzon esta vacio."
  L["BANNER_EARNED"]             = "Total ganado: "
  L["BANNER_SPENT"]              = "Total gastado: "
  L["MSG_RUN_EARNED"]            = "Ganado %s."
  L["MSG_RUN_SPENT"]             = "Gastado %s."
  L["MSG_RUN_EARNED_SPENT"]      = "Ganado %s, gastado %s."

  L["SENDER_UNKNOWN"]            = "Desconocido"
  L["LABEL_GOLD"]                = "Oro: "
  L["LABEL_COD"]                 = "C.R.: "
  L["LABEL_COD_SHORT"]           = "C.R."
  L["STATUS_READ"]               = "Leido"
  L["STATUS_UNREAD"]             = "No leido"
  L["STATUS_RETURNED"]           = "Devuelto"
  L["DETAIL_EXPIRES"]            = "Expira en %.0fd"
  L["DAYS_SHORT"]                = "%.0fd"
  L["LABEL_SALE"]                = "Venta: "
  L["LABEL_DEPOSIT"]             = "Deposito: "
  L["LABEL_AH_COMMISSION"]       = "Com. SC: "
  L["LABEL_PURCHASE"]            = "Compra: "
  L["DETAIL_NO_BODY"]            = "(este correo no lleva texto)"
  L["BTN_BACK"]                  = "<< Volver"
  L["BTN_TAKE_ALL"]              = "Recoger"
  L["BTN_REPLY"]                 = "Responder"
  L["BTN_RETURN"]                = "Devolver"

  -- Acciones en bloque
  L["BTN_DELETE_ALL_DONE"]       = "Eliminar lo vaciado"
  L["CONFIRM_DELETE_ALL_DONE"]   = "Eliminar %s? Esto no se puede deshacer."

  -- Recuentos
  L["COUNT_SLOTS_ONE"]           = "%d espacio"
  L["COUNT_SLOTS_OTHER"]         = "%d espacios"
  L["COUNT_MAILS_ONE"]           = "%d correo"
  L["COUNT_MAILS_OTHER"]         = "%d correos"
  L["COUNT_ITEMS_ONE"]           = "%d objeto"
  L["COUNT_ITEMS_OTHER"]         = "%d objetos"
  L["COUNT_FREE_SLOTS_ONE"]      = "%d espacio libre"
  L["COUNT_FREE_SLOTS_OTHER"]    = "%d espacios libres"

  -- Collection safety
  L["MSG_MAIL_TIMEOUT"]          = "El buzon no respondio a tiempo. Puede que la accion no se completara: vuelve a abrir el buzon y compruebalo."
  L["MSG_ITEM_NOT_COLLECTED"]    = "Sigue en el buzon: este correo no se recogio por completo. No se perdio nada."
  L["MSG_COLLECT_INCOMPLETE"]    = "Recogida detenida: %d correos siguen en el buzon. No se perdio nada: vuelve a abrir el buzon e intentalo de nuevo."
  L["MSG_COLLECT_STOPPED_BAGS"]  = "Recogida detenida: tus bolsas estan llenas. %d correos siguen en el buzon; no se perdio nada."
  L["MSG_ITEM_REFUSED"]          = "No se pudo recoger ese objeto y sigue en el buzon: puede que ya tengas uno, que sea unico o que no puedas llevar mas."
  L["MSG_ITEM_REFUSED_REASON"]   = "No se pudo recoger ese objeto y sigue en el buzon. El juego dice: %s"
  L["MSG_MAIL_PARTIAL"]          = "No se pudieron recoger %d objeto(s) de ese correo y siguen en el buzon: puede que ya los tengas, que sean unicos o que no puedas llevar mas."
  L["MSG_MAIL_PARTIAL_REASON"]   = "No se pudieron recoger %d objeto(s) de ese correo y siguen en el buzon. El juego dice: %s"
  L["MSG_COLLECT_PARTIAL"]       = "Se recogieron %d correos. No se pudieron recoger %d objeto(s) y siguen en el buzon: puede que ya los tengas, que sean unicos o que no puedas llevar mas."
  L["MSG_COLLECT_PARTIAL_REASON"]= "Se recogieron %d correos. No se pudieron recoger %d objeto(s) y siguen en el buzon. El juego dice: %s"
  L["STUCK_LINE"]                = "Sin recoger: %s"
  L["STUCK_GENERIC"]             = "puede que ya tengas uno, que sea unico o que tus bolsas esten llenas"
  L["MSG_BAGS_FULL"]             = "No hay espacio suficiente en las bolsas: se necesitan %d huecos libres y tienes %d. No se recogio nada."
  L["MSG_BAGSPACE_PARTIAL"]      = "No hay espacio suficiente en las bolsas.\n%d correos necesitan %d huecos libres y tienes %d.\nRecoger los %d primeros que quepan?"
  L["BAGSPACE_CONFIRM_ACCEPT"]   = "Recoger lo que quepa"

  L["COD_CONFIRM_ACCEPT"]        = "Pagar y recoger"
  L["COD_CONFIRM_CANCEL"]        = "Cancelar"
  L["COD_CONFIRM_MSG"]           = "Contra reembolso.\nEntregar %s para recoger lo que lleva adjunto?"

  L["LABEL_RECIPIENT"]           = "Destinatario"
  L["LABEL_SUBJECT"]             = "Asunto"
  L["LABEL_MESSAGE"]             = "Mensaje"
  L["LABEL_ATTACHMENTS"]         = "Adjuntos"
  L["LABEL_GOLD_SEND"]           = "Oro:"
  L["LABEL_SEND_COST"]           = "Coste: "
  L["DEFAULT_SUBJECT"]           = "Correo"
  L["DEFAULT_BODY"]              = "Buen provecho!"
  L["BTN_SEND_MAIL"]             = "Enviar correo"
  L["BTN_SEND_MAIL_PENDING"]     = "Enviando..."
  L["MSG_SEND_TIMEOUT"]          = "Sin confirmacion del servidor. Se ha conservado tu borrador: comprueba tu buzon antes de enviarlo otra vez."
  L["MSG_SEND_FAILED"]           = "El correo no se envio. Se ha conservado tu borrador."
  L["ERR_NO_RECIPIENT"]          = "Indica primero a quien se lo envias."
  L["DEFAULT_NO_SUBJECT"]        = "Sin asunto"
  L["ERR_SENDMAIL_UNAVAILABLE"]  = "Falta la funcion SendMail del juego."
  L["ERR_COD_NO_ATTACHMENT"]     = "El contra reembolso necesita algo adjunto que cobrar."
  L["ERR_COD_ZERO_PRICE"]        = "El contra reembolso necesita un importe mayor que cero."
  L["ERR_COD_API_UNAVAILABLE"]   = "Falta la funcion SetSendMailCOD del juego."
  L["TOOLTIP_COD_TITLE"]         = "Contra reembolso"
  L["TOOLTIP_COD_DESC"]          = "No se entrega nada hasta que el destinatario paga el importe que fijes."

  -- Avisos de envio
  L["SEND_RULE_SELF"]            = "No puedes enviarte correo a ti mismo."
  L["SEND_RULE_COD_CAP"]         = "El contra reembolso no puede superar %d de oro."
  L["SEND_RULE_XREALM_WARBAND"]  = "Solo los objetos vinculados a la tropa cambian de reino. Usa el banco de la tropa para el oro y lo demas."
  L["SEND_RULE_XREALM_STRANGER"] = "Solo tus propios personajes pueden recibir objetos u oro en otro reino."
  L["SEND_RULE_DELIVERY_OWN"]    = "Tus otros personajes reciben el correo al instante."
  L["SEND_RULE_DELIVERY_HOUR"]   = "El correo con adjuntos suele llegar en aproximadamente una hora."

  L["CONTACT_RECENTLY_GROUPED"]  = "Agrupado hace poco"
  L["CONTACT_MANUAL"]            = "Anadido por ti"
  L["CONTACT_GUILD"]             = "Hermandad"
  L["CONTACT_ALTS"]              = "Alts"
  L["CONTACT_RECENT"]            = "Recientes"
  L["CONTACT_FRIENDS"]           = "Amigos"
  -- Both lines of the same tooltip, so it cannot come out half Spanish.
  L["CONTACT_FAV_HINT"]          = "Clic derecho en un nombre para anadirlo a favoritos."
  L["CONTACT_HIDE_HINT"]         = "Mayus + clic derecho para ocultarlo de las sugerencias. Puedes recuperarlo en el gestor de destinatarios."
  -- The Send tab's category bar says All in words, from the same key the
  -- recipient manager's filter row uses.
  L["RM_FILTER_ALL"]             = "Todos"
  L["CONTACT_EMPTY_LOADING"]     = "Todavia se esta leyendo esa lista del servidor. Se rellenara sola."
  L["CONTACT_EMPTY_GUILD"]       = "No perteneces a ninguna hermandad."
  L["CONTACT_EMPTY_FRIENDS"]     = "No hay nadie en tu lista de amigos, y ningun amigo de Battle.net esta en un personaje al que puedas escribir."
  L["CONTACT_EMPTY_ALTS"]        = "Aun no hay otros personajes registrados. Conectate con uno con Postbox instalado y aparecera aqui."
  L["CONTACT_EMPTY_RECENT"]      = "Todavia no has enviado ningun correo. Todos aquellos a los que escribas apareceran aqui despues, del mas reciente al mas antiguo."

  -- Gestor de destinatarios
  L["RM_BTN_NOTE"]               = "Nota"
  L["RM_TIP_NOTE"]               = "Unas palabras tuyas sobre este personaje. La nota aparece junto al nombre en ambas ventanas."
  L["RM_TIP_ROW_FAV"]            = "Clic derecho en la fila para anadir o quitar un favorito."
  L["RM_EMPTY_FILTER_HINT"]      = "Elige otra categoria arriba, o Todos para ver todos los destinatarios."

  -- Opciones
  L["OPT_TAB_COUNTS_TITLE"]      = "Mostrar los recuentos"
  L["OPT_TAB_COUNTS_DESC"]       = "Pone el numero de correos en cada segmento, contando todo lo que pase de 99 como 99+."
  L["OPT_COMPACT_ROWS_TITLE"]    = "Filas de correo compactas"
  L["OPT_COMPACT_ROWS_DESC"]     = "Muestra mas correos a la vez dando una sola linea a cada uno, con lo que omite en la informacion de la fila."
  L["OPT_PREVIEW_CLICK_TITLE"]   = "El clic abre el correo"
  L["OPT_PREVIEW_CLICK_DESC"]    = "El clic izquierdo abre el correo y Mayus-clic o clic derecho lo recoge; desactivado, los dos se intercambian."
  L["OPT_MINIMAP_HEADING"]       = "Minimapa"
  L["OPT_MINIMAP_TITLE"]         = "Icono de correo del minimapa"
  L["OPT_MINIMAP_DESC"]          = "Sustituye el icono de correo nuevo por el propio de Postbox en el borde del minimapa; muevelo con Mayus y arrastrar."
  L["OPT_MINIMAP_DESC_EUI"]      = "Da al icono de correo del minimapa de EllesmereUI el estilo que elijas abajo."
  L["OPT_MINIMAP_ICON_TITLE"]    = "Icono"
  L["OPT_MINIMAP_ICON_POSTBOX"]  = "Sobre"
  L["OPT_MINIMAP_ICON_BLIZZARD"] = "Blizzard"
  L["OPT_MINIMAP_ICON_CLEAN"]    = "Minimalista"
  L["OPT_MINIMAP_ICON_MAILBOX"]  = "Buzon"
  L["OPT_MINIMAP_SIZE_TITLE"]    = "Tamano del icono"
  L["OPT_MINIMAP_SIZE_STEP"]     = "%d px"
  L["OPT_MINIMAP_POS_TITLE"]     = "Posicion"
  L["OPT_MINIMAP_POS_TR"]        = "Arriba a la derecha"
  L["OPT_MINIMAP_POS_TL"]        = "Arriba a la izquierda"
  L["OPT_MINIMAP_POS_BR"]        = "Abajo a la derecha"
  L["OPT_MINIMAP_POS_BL"]        = "Abajo a la izquierda"
  L["OPT_MINIMAP_POS_CUSTOM"]    = "Personalizada (Mayus y arrastrar)"
  L["OPT_MINIMAP_ACCENT_TITLE"]  = "Color de acento"
  L["OPT_MINIMAP_ACCENT_DESC"]   = "Tine el sobre y su brillo con el color de acento, siguiendo el de EllesmereUI cuando su apariencia esta activa."
  L["OPT_MINIMAP_GLOW_TITLE"]    = "Brillo"
  L["OPT_MINIMAP_GLOW_DESC"]     = "Un brillo suave tras el icono mientras espera correo."
  L["OPT_MINIMAP_RESET_POS"]     = "Restablecer la posicion del icono"
  L["OPT_MINIMAP_RESET_POS_DESC"] = "Devuelve el icono a su lugar por defecto en el borde del minimapa."
  L["OPT_MINIMAP_EUI_STYLED"]    = "El minimapa de EllesmereUI esta activo, asi que su icono de correo lleva el estilo; la posicion y el tamano vienen de las opciones del minimapa de EllesmereUI."
  L["MINIMAP_TIP_HINT"]          = "Clic: opciones. Mayus y arrastrar: mover."
  L["MINIMAP_TOGGLE_ON"]         = "Icono de correo del minimapa: activado."
  L["MINIMAP_TOGGLE_OFF"]        = "Icono de correo del minimapa: desactivado."
end

-------------------------------------------------------------
-- Russian (ruRU). The one block with a three-form plural rule -- see
-- RuleRussian at the top of this file.
-------------------------------------------------------------
if GetLocale() == "ruRU" then
-- Чат и диалоги
L["ERR_OPEN_MAILBOX_LOOT"]     = "Подойдите к почтовому ящику и откройте его."
L["POPUP_OK"]                  = "Закрыть"

-- Окно, вкладки, строка состояния
L["FRAME_TITLE"]               = "Postbox"
L["TAB_COLLECT"]               = "Сбор"
L["TAB_SEND"]                  = "Отправка"
L["STATUS_READY"]              = "Готов"
L["STATUS_REMAINING"]          = "Осталось: %d"
L["STATUS_DONE"]               = "Готово"
L["STATUS_STOPPED"]            = "Прервано: ящик закрылся"
L["STATUS_INCOMPLETE"]         = "Не завершено: осталось %d"
L["STATUS_PARTIAL"]            = "Завершено: не забрано %d"
L["STATUS_STUCK"]              = "Застряло: %d"

-- Названия категорий: и кнопка массового сбора, и метка на строке письма.
L["CAT_ALL"]                   = "Вся почта"
L["CAT_EXPIRED"]               = "Истекшие"
L["CAT_SOLD"]                  = "Продано"
L["CAT_CANCELED"]              = "Отменено"
L["CAT_BOUGHT"]                = "Куплено"
L["CAT_OTHER"]                 = "Другое"

-- Сегменты и список
L["VIEW_TO_COLLECT"]           = "Сбор"
L["VIEW_DONE"]                 = "Готово"
L["VIEW_ALL"]                  = "Все"
L["HINT_COD"]                  = "Наложенный платёж сам собой не забирается."
L["HINT_ROW_PREVIEW"]          = "Shift-клик или правый клик: открыть без получения"
L["HINT_ROW_COLLECT"]          = "Shift-клик или правый клик: получить письмо"
L["HINT_ROW_DELETE"]           = "Насовсем удаляет это письмо из почтового ящика."
L["EMPTY_LIST"]                = "Получать нечего."
L["EMPTY_LIST_DONE"]           = "Пока ничего не разобрано."
L["EMPTY_LIST_ALL"]            = "Почтовый ящик пуст."
L["BANNER_EARNED"]             = "Всего заработано: "
L["BANNER_SPENT"]              = "Всего потрачено: "
L["MSG_RUN_EARNED"]            = "Заработано: %s."
L["MSG_RUN_SPENT"]             = "Потрачено: %s."
L["MSG_RUN_EARNED_SPENT"]      = "Заработано: %s, потрачено: %s."

-- Одно письмо: строка списка и открытый вид
L["SENDER_UNKNOWN"]            = "Неизвестно"
L["LABEL_GOLD"]                = "Золото: "
L["LABEL_COD"]                 = "Налож. платеж: "
L["LABEL_COD_SHORT"]           = "Налож."
L["STATUS_READ"]               = "Прочитано"
L["STATUS_UNREAD"]             = "Не прочитано"
L["STATUS_RETURNED"]           = "Возвращено"
L["DETAIL_EXPIRES"]            = "Осталось %.0f д."
L["DAYS_SHORT"]                = "%.0f д."
L["LABEL_SALE"]                = "Продажа: "
L["LABEL_DEPOSIT"]             = "Залог: "
L["LABEL_AH_COMMISSION"]       = "Комиссия аукциона: "
L["LABEL_PURCHASE"]            = "Покупка: "
L["DETAIL_NO_BODY"]            = "(в этом письме нет текста)"
L["BTN_BACK"]                  = "<< Назад"
L["BTN_TAKE_ALL"]              = "Забрать"
L["BTN_REPLY"]                 = "Ответить"
L["BTN_RETURN"]                = "Вернуть"

-- Массовые действия
L["BTN_DELETE_ALL_DONE"]       = "Удалить все разобранные"
L["CONFIRM_DELETE_ALL_DONE"]   = "Удалить %s? Это действие необратимо."

-- Счётные формы. Русский требует трёх: 1 слот / 2-4 слота / 5-20 слотов,
-- при этом 11-14 всегда берут форму MANY. Правило в ns.PluralForm.
L["COUNT_SLOTS_ONE"]           = "%d слот"
L["COUNT_SLOTS_FEW"]           = "%d слота"
L["COUNT_SLOTS_MANY"]          = "%d слотов"
L["COUNT_MAILS_ONE"]           = "%d письмо"
L["COUNT_MAILS_FEW"]           = "%d письма"
L["COUNT_MAILS_MANY"]          = "%d писем"
L["COUNT_ITEMS_ONE"]           = "%d предмет"
L["COUNT_ITEMS_FEW"]           = "%d предмета"
L["COUNT_ITEMS_MANY"]          = "%d предметов"
L["COUNT_FREE_SLOTS_ONE"]      = "%d свободный слот"
L["COUNT_FREE_SLOTS_FEW"]      = "%d свободных слота"
L["COUNT_FREE_SLOTS_MANY"]     = "%d свободных слотов"

-- Collection safety
L["MSG_MAIL_TIMEOUT"]          = "Почтовый ящик не ответил вовремя. Действие могло не завершиться — откройте ящик заново и проверьте."
L["MSG_ITEM_NOT_COLLECTED"]    = "Осталось в почтовом ящике: это письмо забрано не полностью. Ничего не потеряно."
L["MSG_COLLECT_INCOMPLETE"]    = "Сбор остановлен: %d писем осталось в почтовом ящике. Ничего не потеряно — откройте ящик заново и повторите."
L["MSG_COLLECT_STOPPED_BAGS"]  = "Сбор остановлен: сумки заполнены. %d писем осталось в почтовом ящике — ничего не потеряно."
L["MSG_ITEM_REFUSED"]          = "Этот предмет не удалось забрать, он остался в почтовом ящике — возможно, он у вас уже есть, он уникальный или вы не можете нести больше."
L["MSG_ITEM_REFUSED_REASON"]   = "Этот предмет не удалось забрать, он остался в почтовом ящике. Игра сообщает: %s"
L["MSG_MAIL_PARTIAL"]          = "Не удалось забрать %d предмет(ов) из этого письма, они остались в почтовом ящике — возможно, они у вас уже есть, они уникальные или вы не можете нести больше."
L["MSG_MAIL_PARTIAL_REASON"]   = "Не удалось забрать %d предмет(ов) из этого письма, они остались в почтовом ящике. Игра сообщает: %s"
L["MSG_COLLECT_PARTIAL"]       = "Забрано писем: %d. Не удалось забрать %d предмет(ов), они остались в почтовом ящике — возможно, они у вас уже есть, они уникальные или вы не можете нести больше."
L["MSG_COLLECT_PARTIAL_REASON"]= "Забрано писем: %d. Не удалось забрать %d предмет(ов), они остались в почтовом ящике. Игра сообщает: %s"
L["STUCK_LINE"]                = "Не забрано: %s"
L["STUCK_GENERIC"]             = "возможно, он у вас уже есть, он уникальный или сумки заполнены"
L["MSG_BAGS_FULL"]             = "Недостаточно места в сумках: нужно %d свободных ячеек, у вас %d. Ничего не забрано."
L["MSG_BAGSPACE_PARTIAL"]      = "Недостаточно места в сумках.\n%d писем требуют %d свободных ячеек, у вас %d.\nЗабрать первые %d, которые поместятся?"
L["BAGSPACE_CONFIRM_ACCEPT"]   = "Забрать что поместится"

-- Диалог наложенного платежа
L["COD_CONFIRM_ACCEPT"]        = "Оплатить и забрать"
L["COD_CONFIRM_CANCEL"]        = "Отмена"
L["COD_CONFIRM_MSG"]           = "Наложенный платёж.\nОтдать %s, чтобы взять приложенное?"

-- Составление письма
L["LABEL_RECIPIENT"]           = "Получатель"
L["LABEL_SUBJECT"]             = "Тема"
L["LABEL_MESSAGE"]             = "Сообщение"
L["LABEL_ATTACHMENTS"]         = "Вложения"
L["LABEL_GOLD_SEND"]           = "Золото:"
L["LABEL_SEND_COST"]           = "Стоимость: "
L["DEFAULT_SUBJECT"]           = "Почта"
L["DEFAULT_BODY"]              = "Держи!"
L["BTN_SEND_MAIL"]             = "Отправить"
L["BTN_SEND_MAIL_PENDING"]     = "Отправка..."
L["MSG_SEND_TIMEOUT"]          = "Нет подтверждения от сервера. Черновик сохранён — проверьте почту, прежде чем отправлять снова."
L["MSG_SEND_FAILED"]           = "Письмо не отправлено. Черновик сохранён."
L["ERR_NO_RECIPIENT"]          = "Сначала укажите, кому отправить."
L["DEFAULT_NO_SUBJECT"]        = "Без темы"
L["ERR_SENDMAIL_UNAVAILABLE"]  = "Игровая функция SendMail отсутствует."
L["ERR_COD_NO_ATTACHMENT"]     = "Для наложенного платежа нужно что-то приложить."
L["ERR_COD_ZERO_PRICE"]        = "Для наложенного платежа нужна сумма больше нуля."
L["ERR_COD_API_UNAVAILABLE"]   = "Игровая функция SetSendMailCOD отсутствует."
L["TOOLTIP_COD_TITLE"]         = "Наложенный платеж"
L["TOOLTIP_COD_DESC"]          = "Ничего не выдаётся, пока получатель не заплатит указанную вами сумму."

-- Подсказки при отправке
L["SEND_RULE_SELF"]            = "Нельзя отправить письмо самому себе."
L["SEND_RULE_COD_CAP"]         = "Наложенный платеж не может превышать %d зол."
L["SEND_RULE_XREALM_WARBAND"]  = "На другой игровой мир попадают только предметы, привязанные к отряду. Для золота и прочего - банк отряда."
L["SEND_RULE_XREALM_STRANGER"] = "Получать предметы и золото в другом игровом мире могут только ваши собственные персонажи."
L["SEND_RULE_DELIVERY_OWN"]    = "Ваши другие персонажи получают почту мгновенно."
L["SEND_RULE_DELIVERY_HOUR"]   = "Письмо с вложениями обычно приходит примерно через час."

-- Категории окна получателей
L["CONTACT_RECENTLY_GROUPED"]  = "Недавно в группе"
L["CONTACT_MANUAL"]            = "Добавлено вами"
L["CONTACT_GUILD"]             = "Гильдия"
L["CONTACT_ALTS"]              = "Альты"
L["CONTACT_RECENT"]            = "Недавние"
L["CONTACT_FRIENDS"]           = "Друзья"
-- Both lines of the same tooltip, so it cannot come out half Russian.
L["CONTACT_FAV_HINT"]          = "Правый клик по имени добавляет его в избранное."
L["CONTACT_HIDE_HINT"]         = "Shift + правый клик убирает имя из подсказок. Вернуть его можно в окне получателей Postbox."
-- The Send tab's category bar says All in words, from the same key the
-- recipient manager's filter row uses.
L["RM_FILTER_ALL"]             = "Все"
L["CONTACT_EMPTY_LOADING"]     = "Этот список ещё читается с сервера. Он заполнится сам."
L["CONTACT_EMPTY_GUILD"]       = "Вы не состоите в гильдии."
L["CONTACT_EMPTY_FRIENDS"]     = "В списке друзей никого нет, и ни один друг из Battle.net не находится на персонаже, которому вы могли бы написать."
L["CONTACT_EMPTY_ALTS"]        = "Другие персонажи ещё не записаны. Зайдите на одного из них с установленным Postbox, и он появится здесь."
L["CONTACT_EMPTY_RECENT"]      = "Вы ещё не отправляли писем. Все, кому вы напишете, появятся здесь — сначала самые недавние."

-- Управление получателями
L["RM_BTN_NOTE"]               = "Заметка"
L["RM_TIP_NOTE"]               = "Несколько ваших слов об этом персонаже. Заметка отображается рядом с именем в обоих окнах."
L["RM_TIP_ROW_FAV"]            = "Правый клик по строке, чтобы добавить или убрать избранное."
L["RM_EMPTY_FILTER_HINT"]      = "Выберите другую категорию выше или «Все», чтобы увидеть всех получателей."

-- Настройки
L["OPT_TAB_COUNTS_TITLE"]      = "Показывать счётчики"
L["OPT_TAB_COUNTS_DESC"]       = "Показывает число писем на каждом сегменте, а всё, что больше 99, — как 99+."
L["OPT_COMPACT_ROWS_TITLE"]    = "Компактные строки писем"
L["OPT_COMPACT_ROWS_DESC"]     = "Показывает больше писем сразу, отводя каждому одну строку, а всё остальное — во всплывающей подсказке."
L["OPT_PREVIEW_CLICK_TITLE"]   = "Клик открывает письмо"
L["OPT_PREVIEW_CLICK_DESC"]    = "Левый клик открывает письмо, а Shift-клик или правый клик получает его; выключено — они меняются местами."
L["OPT_MINIMAP_HEADING"]       = "Миникарта"
L["OPT_MINIMAP_TITLE"]         = "Значок почты у миникарты"
L["OPT_MINIMAP_DESC"]          = "Заменяет стандартный значок новой почты собственным значком Postbox на краю миникарты; перетаскивайте его с зажатым Shift."
L["OPT_MINIMAP_DESC_EUI"]      = "Оформляет значок почты миникарты EllesmereUI выбранным ниже стилем."
L["OPT_MINIMAP_ICON_TITLE"]    = "Значок"
L["OPT_MINIMAP_ICON_POSTBOX"]  = "Конверт"
L["OPT_MINIMAP_ICON_BLIZZARD"] = "Blizzard"
L["OPT_MINIMAP_ICON_CLEAN"]    = "Минимальный"
L["OPT_MINIMAP_ICON_MAILBOX"]  = "Почтовый ящик"
L["OPT_MINIMAP_SIZE_TITLE"]    = "Размер значка"
L["OPT_MINIMAP_SIZE_STEP"]     = "%d пикс."
L["OPT_MINIMAP_POS_TITLE"]     = "Положение"
L["OPT_MINIMAP_POS_TR"]        = "Сверху справа"
L["OPT_MINIMAP_POS_TL"]        = "Сверху слева"
L["OPT_MINIMAP_POS_BR"]        = "Снизу справа"
L["OPT_MINIMAP_POS_BL"]        = "Снизу слева"
L["OPT_MINIMAP_POS_CUSTOM"]    = "Своё (Shift + перетаскивание)"
L["OPT_MINIMAP_ACCENT_TITLE"]  = "Акцентный цвет"
L["OPT_MINIMAP_ACCENT_DESC"]   = "Окрашивает конверт и свечение в акцентный цвет — при активном оформлении EllesmereUI в его акцент."
L["OPT_MINIMAP_GLOW_TITLE"]    = "Свечение"
L["OPT_MINIMAP_GLOW_DESC"]     = "Мягкое свечение позади значка, пока ждёт почта."
L["OPT_MINIMAP_RESET_POS"]     = "Сбросить положение значка"
L["OPT_MINIMAP_RESET_POS_DESC"] = "Возвращает значок на место по умолчанию на краю миникарты."
L["OPT_MINIMAP_EUI_STYLED"]    = "Миникарта EllesmereUI активна, поэтому стиль применяется к её значку почты; положение и размер задаются в настройках миникарты EllesmereUI."
L["MINIMAP_TIP_HINT"]          = "Клик: настройки. Shift + перетаскивание: переместить."
L["MINIMAP_TOGGLE_ON"]         = "Значок почты у миникарты: включён."
L["MINIMAP_TOGGLE_OFF"]        = "Значок почты у миникарты: выключен."
end