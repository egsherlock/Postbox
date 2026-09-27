# Changelog

## 1.41.0

**Make Postbox yours.** Arrange your mail rows and buttons right in the
window, give your alts buttons of their own, and hide the characters you no
longer play.
*After updating, restart the game once (a /reload is not enough).*

### New

- **Arrange your mail rows.** The grip beside the options cog lets you drag
  a row's columns into your own order, hide the ones you don't need, and set
  gold and time left on the spot. The Mail tab, History and Mail Memory all
  follow it.
- **Arrange the category buttons too:** drag them into your order and hide
  the ones you never use; the list gets the room.
- **Character groups.** Put characters together (your bank alts, your
  crafters, a friend who sends you materials) and each group gets a button
  that collects everything they sent. Make them in Options, Mail tab, or
  right-click From alts.
- **Hide a character** from the character list with a right-click. Postbox
  still remembers its mail; Show brings it back.
- **Reset to defaults**, at the foot of the options, puts every setting and
  window back the way Postbox ships, after asking. Your recipients, groups,
  Mail Memory and History are kept.

### Improved

- **Postbox follows EllesmereUI's look.** On Blizzard Style or Classic WoW UI
  it wears its own Blizzard look, to match your other windows.
- **EllesmereUI profile, Dark Mode and accent changes** reach an open mailbox
  straight away.
- Also: the "Show on each mail" list moved from the options into the window,
  Mail Memory rows show the read mark, "Flash on new mail" greys out while
  the minimap icon is off, and the window border no longer offers "Match
  EllesmereUI", which never drew a border.

### Fixed

- Questions asked from the options, the groups window or the recipient
  manager (a reload, a delete, a note) no longer open hidden behind them.
- On EllesmereUI's round minimaps the mail icon sits on the rim, and on the
  Classic ring it shows whole.
- With EllesmereUI's Modern window style, lowering the opacity no longer
  brings the EllesmereUI backdrop back underneath.

## 1.40.1

### Improved

- **Read mail stays in the list**, under a divider that waits at the foot of
  a long inbox with **Delete all**. Click the divider to fold it away;
  Postbox remembers.

### Fixed

- No more stray scroll bar on a list that already fits.
- The resize hint no longer reappears while you drag.
- The "Read, nothing left" bar no longer shows mail through it or leaves a
  gap at the bottom.

## 1.40.0

**The biggest Postbox update yet.** Every character's mailbox in one place, a
History of everything you collect, and a tidier inbox.
*After updating, restart the game once (a /reload is not enough) so Postbox
shows up in the minimap's addon menu.*

### New

- **Every character's mailbox, in one place.** Mail Memory remembers what each
  of your characters has waiting. Check any of them from the minimap icon,
  wherever you are, or right in the Mail tab when you are at a mailbox, and
  search all of them at once.
- **History.** The clock beside Inbox lists everything Postbox collected: when,
  from whom, what it was worth, and what each letter said. It keeps a week, or
  up to a month if you like.
- **Warnings before mail is lost.** Postbox tells you when mail on another
  character is about to expire, or has been waiting on a character you have
  not played in weeks.
- **See new mail before you reach a mailbox.** Auctions that sell, expire or
  are bought while you are away show up in Mail Memory by item name.
- **From alts.** A new button collects everything your own characters sent
  you, on any realm.
- **Alt+right-click attaches every stack** of an item at once; whatever does
  not fit waits in the queue.
- **Postbox speaks Traditional Chinese (繁體中文),** translated by samuelbears,
  who also brought us Simplified Chinese. Thank you! If a word reads oddly,
  please say so on GitHub.

### Improved

- **One tidy inbox.** Mail still to collect comes first. Read mail with
  nothing left in it folds away under a divider that deletes it in one click.
  Rather have it elsewhere? Options can give it a tab of its own, or delete it
  for you as you go (History keeps what it said).
- **Compact rows by default,** lined up in neat columns. You choose what each
  row shows (gold, slots, time left) and in what order; "Larger mail rows"
  brings the two-line rows back.
- **Clearer counts.** Inbox counts everything in the box, each button counts
  what it would collect, and a button with nothing to do is greyed out.
- **Crafted items and reagents show their quality mark** on the icon.
- **Handy shortcuts:** click "Stuck" in the title bar to see only the mail the
  game would not hand over, right-click "Attachments" to empty a mail you are
  writing, and clear a search with one click. "AH Bought" is back, and its
  button now leads the row.
- **Faster** on big mailboxes and long histories, and the options fit on
  screen again.
- Also: names without the realm, searching "sold" or "AH" finds auction mail,
  Mail Memory can list what expires first and be made wider, the resize grips
  explain themselves, and the new-mail sound and flash work with Mail Memory
  switched off.

### Fixed

- The minimap icon's tooltip could say "Nothing waiting" on a character whose
  mail had arrived while it was logged out.
- "Stuck" warnings could appear on mail that was never refused.
- Buying from the auction house played the new-mail alert twice.
- The Postbox Modern look could interfere with other addons' tooltips.
- Mail Memory lost track past 50 mails, and one of its tooltips could cause an
  error.

## 1.39.0

### New

- **Postbox speaks Simplified Chinese**: every window, message and tooltip,
  translated by samuelbears. Thank you!
- Traditional Chinese still shows English. It needs a translation of its own,
  and contributions are welcome.

## 1.38.0

### New

- **The queue is visible.** Items waiting to be sent sit in a grid beside the
  attachment slots, in order, and are greyed in your bags. Hover one for
  details, right-click to take it out.
- **A run of mails explains itself.** Send confirms the run first (mails,
  items, total postage), counts it off as it goes ("Sending 2 of 3..."), and
  says when the game is waiting for your answer about an item.
- **Ctrl+Enter sends**, from any field.
- **Padlocks in EllesmereUI's bags and Baganator** on items that cannot be
  mailed, while the Send tab is open.

### Improved

- **Money has its own column** in the mail list: green for gold arriving,
  amber for a C.O.D. price, red for what a won auction cost.
- **Time left shows on the row only when a mail is about to go** (under three
  days, or under a day for C.O.D.). The tooltip always has it.
- **Enter takes a completed name whole**, realm included, and **Tab moves
  straight to the next suggestion.**
- **A mail with no subject is titled after its first item**, as the game does
  it.
- Also: the totals line is shorter and stays inside the window, resizing is
  free again, and "All bought" is now "All won".

### Fixed

- A queued item the game asks about first (a recent purchase you could still
  return) repeated its dialog after the first mail went. It is now asked once,
  on its turn.
- Attached and unmailable items lost their greying in EllesmereUI's bags and
  Baganator after switching tabs.
- The postage shown covered only the first mail of a run.

## 1.37.0

### New

- **Pick the mails to collect.** Shift-click selects a range, Ctrl-click picks
  single rows, and the big button reads "Collect 5 selected".
- **Right-click the resize grip** to put the window back to its default size.
- **Gold in a mail is a coin tile** in the reading view: click it to take just
  the gold.

### Improved

- **Auction rows say what happened**: "AH Won", "AH Sold", "AH Expired" or
  "AH Cancelled", with the item's name.
- **The options panel is two columns**, in the window's order.
- **A slim scroll bar** on every list, shown only when something is off
  screen.
- Also: a tidier reading view, whole rows at the smallest window size, and
  "Attachments 3/12" counts up with the queued count beside it.

### Fixed

- Queuing a thirteenth attachment did nothing under some bag addons. It works
  with every bag addon now.
- A recipient favourited from the recipient manager could be filed under a
  lowercase name.

## 1.36.0

### New

- **Post more than twelve items in one go.** With every slot full,
  right-clicked items queue up, and "Send 3 mails" posts them all to the same
  person. Gold and C.O.D. go with the first mail.
- **Search the inbox** by sender or subject. The big button then reads
  "Collect shown".
- **Return to sender** on any mail the game lets you return, not only C.O.D.
- **An unsent draft survives leaving the mailbox**: recipient, subject and
  message come back at the next one. Attachments and gold cannot, because the
  game drops them.

### Improved

- Enter moves from Recipient to Subject to the message, as in the game's own
  send window.

## 1.35.0

### New

- **"Keep recipient after send"**: the name stays in the Recipient box after a
  mail goes, for a run of mails to the same alt. Off to begin with.
- **"Show category buttons"**: switch it off to hide the five sweep buttons
  under the list and give the list two more rows. On to begin with.

### Improved

- **If another addon brings Blizzard's mail window back beside Postbox's,
  Postbox puts it away again**, and `/postbox debug` names the addon.

### Fixed

- Tab in the recipient box skipped rows and sometimes seemed not to move. It
  now steps down one row per press, Shift+Tab steps back, and Escape still
  restores what you typed.
- Cyrillic names in the address book: a favourite's first letter drew as a
  box, a chosen name arrived one letter short, and picking one from Alts,
  Friends or Guild did nothing. A Cyrillic name typed in lowercase is found
  now, and accented names sort under their own letter.

## 1.34.0

### Improved

- **Right-clicking a bag item at the mailbox uses it again**, instead of
  attaching it to a new mail, so you can equip or open what just arrived.
  Prefer the old way? Switch on "Attach from the Mail tab". The Send tab
  attaches on right-click either way.
- **`/postbox debug` makes a report worth pasting**: every setting (the ones
  you changed marked), your window and look, realm, address book size, other
  addons that touch mail, bags or skinning, and Postbox's last five errors. It
  leaves out your character name and your full addon list.
- The report window is bigger, so the report fits.

## 1.33.4

### Fixed

- The dot beside "Inheriting EllesmereUI settings" is level with the text at
  last.

## 1.33.3

### Fixed

- The dot beside "Inheriting EllesmereUI settings" moves back down: 1.33.2
  had moved it the wrong way.
- Every section heading in the options sits the same distance above its box.

## 1.33.2

### Improved

- The badge on the Appearance heading reads "Inheriting EllesmereUI
  settings".

### Fixed

- The badge's dot sat below the middle of the letters.
- The Appearance heading sat closer to its box than every other section's.

## 1.33.1

### Improved

- **"Strong" borders look strong.** They were too close to "Light".
- "Following your EllesmereUI settings" moved onto the Appearance heading,
  where the Minimap section's switch sits.

### Fixed

- On Postbox Modern, a larger border size ate into the window instead of
  drawing a thicker border. The background now runs to the window's edge,
  with the border on top.

## 1.33.0

### New

- **Choose Postbox's own look even with EllesmereUI or ElvUI.** Your UI
  pack's look is still the default, but the Window style dropdown now offers
  your pack, Blizzard and Postbox Modern.
- **Postbox Modern has its own border and transparency settings**, applied
  the moment you pick them.

### Improved

- **The options say which look is in use**: "Following your EllesmereUI
  settings" or "Overriding EllesmereUI". Your minimap icon stays your pack's
  either way.
- **Style and Appearance are one section**, and its controls follow the style
  you choose.
- Under a UI pack, Postbox Modern leaves your tooltips alone.

## 1.32.3

Nothing you can see changed.

## 1.32.2

### Improved

- **The timer added in 1.32.1 is gone.** Postbox checks EllesmereUI's icon
  only when you hover or click, and runs no repeating timers at all.

### Fixed

- The new-mail flash never showed under EllesmereUI.

## 1.32.1

### Fixed

- Under EllesmereUI, hovering anywhere on the minimap made the mouseover
  button row flash.

## 1.32.0

### Improved

- **Under EllesmereUI, the mail icon does everything it does elsewhere**: the
  full Postbox tooltip, left-click for the mailbox memory, right-click for the
  options. Where it sits and when it shows stay EllesmereUI's business.

## 1.31.0

### Improved

- **The new-mail flash is smooth**: a soft halo swells behind the icon, twice,
  instead of the icon growing in visible steps. The icon itself never moves.

## 1.30.5

### Fixed

- The window could not be dragged by the right-hand end of its title bar,
  where the "Collected / Stuck" line sits. Every window style was affected;
  all are fixed.
- The mailbox memory window can be dragged from anywhere on it too.

## 1.30.4

### Improved

- **The new-mail flash grows again**, without sliding across the minimap: the
  icon breathes once and settles.

### Fixed

- Postbox Modern's title, close button and cog line up with the title bar and
  with each other.

## 1.30.3

### Improved

- **The new-mail flash is the glow breathing deeper**: behind the icon, twice,
  then fading back into it.

### Fixed

- Postbox Modern's title bar stopped short of the window, leaving a gap at the
  left and the close button outside it.

## 1.30.2

### Improved

- **The new-mail flash is a soft halo**, swelling and fading twice, instead of
  the icon jumping in size.
- A stuck mail in the mailbox memory wears the same warning triangle as in
  the mail list.
- The mailbox memory shows a tooltip only when you hover the item, so
  scanning the list no longer drags one along.

### Fixed

- The mailbox memory's "new mail arrived" tooltip showed "%d" instead of the
  count.

## 1.30.1

### Fixed

- Postbox Modern's title, close button and cog sat low in the title bar.
  They line up now.

## 1.30.0

### Improved

- **Postbox Modern styles its own tooltips** and leaves every other tooltip
  as it was. Under EllesmereUI or ElvUI nothing changes.
- **The minimap tooltip separates waiting from refused**: "Waiting to
  collect: 5", "Could not be collected: 1". A stuck mail no longer counts
  twice.
- **Changing the window style offers to reload** (Reload now or Later)
  instead of printing an instruction in chat.
- Also: a stuck mail is marked in the same place in the mailbox memory as in
  the mail list, and Modern's title sits centred in its bar.

## 1.29.0

### Improved

- **Colour means something again**: green for good news (mail arrived),
  orange for attention (something could not be collected), and the accent for
  what you picked.
- **The Mail tab's dot shows the state**: orange when something could not be
  collected, the accent otherwise.
- **Mail alerts have their own section** in the options: sound, flash and the
  mailbox memory, out of the Minimap section.
- A stuck mail is marked in the mailbox memory too, with the same orange "!".

## 1.28.0

### Improved

- **The minimap tooltip is Postbox's own**: what has arrived since you last
  looked, what is waiting by sender, and how many the game refused to hand
  over.
- **The dropdown selection marker is a dot**, and every caption starts in the
  same place.
- **Borders land on whole pixels**, so hairlines look even at any UI scale.

### Fixed

- A mail you opened but could not empty, such as a stuck Postmaster mail, was
  missing from the tooltip. It counts now, with "1 could not be collected"
  underneath.

## 1.27.0

### New

- **Optional alerts when mail arrives**: a sound (the game's mail chime) and a
  flash on the icon. Both off by default, in the Minimap section.

### Improved

- **Postbox Modern's edges are clean**: a faint light hairline instead of a
  black one that smeared where two elements sat close.
- **Modern has a title bar again**, and skins the scroll bars too.
- **The minimap tooltip breaks your mailbox down by sender** ("Auction House
  x5") instead of the game's three bare names.
- The Mail tab's caption defaults to the quiet dot.

## 1.26.0

### New

- **The All view can be switched off**, with a new General option.

### Improved

- **A Style section in the options** names the skin painting the window, or
  offers the choice when there is none. The footer keeps the version and a
  **Report a bug** label.
- **The mailbox memory's new-mail badge is a real badge**; hover it for a
  summary by sender.
- **Postbox Modern draws its own close button**, a crisp X in the accent.
- The Mail tab drops its standing note about C.O.D. mail; the confirmation
  dialog says it when it matters.

## 1.25.0

### New

- **A window style of your own: "Postbox Modern".** On the plain Blizzard UI,
  a Style choice offers Blizzard (still the default) or Postbox Modern: flat
  near-black surfaces, hairline borders, the accent doing the talking. Under
  EllesmereUI or ElvUI the choice does not appear. Takes effect after a
  /reload.
- **German, Spanish and Russian are fully translated**: about ninety strings
  each no longer fall back to English.

### Improved

- **The minimap icon's tooltip leads with what your mailbox held** ("Last seen
  2 h ago — 12 mails"), so you know whether the trip is worth it.

## 1.24.7

### Improved

- The mailbox memory window closes itself when you open a real mailbox.

## 1.24.6

### Fixed

- The "+ new mail" badge could never show if a mailbox visit ended without
  Postbox noticing. It now catches that and keeps the arrivals.

## 1.24.5

### Improved

- The Manage Recipients button is a neutral near-black instead of warm
  brown.

### Fixed

- Buying at the auction house did not light the "+ new mail" badge when you
  already had unread mail, because the game sends no signal then. Postbox
  reacts to the purchase itself now, and the badge credits the Auction House.

## 1.24.4

### Fixed

- After updating, the "+ new mail" badge needed one more mailbox visit before
  it could work. It works straight away now.

## 1.24.3

### Fixed

- The "+ new mail" badge kept missing arrivals. It now watches for them three
  ways, which even catches mail that arrived while you were logged out.
- The Manage Recipients button was see-through on the plain UI. It has a real
  background now.

## 1.24.2

### Improved

- The sealed letters are one family, **Sealed letter 1–4**, with the two
  Letter bundles right after them in the icon list.

### Fixed

- The "+ new mail" badge stayed lit for anyone with unread mail. It now marks
  only arrivals Postbox saw this session.
- The Manage Recipients portrait reads as a button on the plain UI.

## 1.24.1

### Improved

- Clearer names: "Blizzard's own spot" is now "Blizzard's default", and icon
  variants that said "clean" are now "2" ("Letter 2", "London Postbox 2").
- The Manage Recipients portrait has a slightly lifted tone on the plain UI,
  so it reads as a button rather than a hole.

### Fixed

- A missed event could hide the "+ new mail" badge. The badge also checks the
  game's new-mail flag whenever the memory window opens.

## 1.24.0

### Improved

- **Right-click-to-attach is simply how Postbox works now**, and the option is
  gone: with a mail window open, right-clicking an item flips to Send with it
  attached, as Blizzard's own Send tab does.
- **The minimap icon's tooltip lists its gestures** (Click, Right-click,
  Shift-drag, Alt-click), each only while it applies.
- **Mailbox memory opens at six rows**, and its "+ new mail" badge appears the
  moment mail lands, even with the window open.
- The position list says "Minimap" instead of "Map edge".

### Fixed

- The Manage Recipients button looked smeared on the plain UI, and the
  options cog sat off the title's line.

## 1.23.0

### Improved

- **Switching the minimap icon on looks good straight away**: fresh setups
  get the Letter icon at the top right with glow, pulse and shadow on.
  Existing setups keep their choices.
- **The position list says where each choice anchors**: "Blizzard's own
  spot", "Map edge - top right", "Map edge - custom", "Anywhere on screen".
- **Alt-click the minimap icon to lock or unlock its position**; its tooltip
  says which.
- **The mailbox memory separates "seen" from "since"**: a "+ new mail" badge
  appears only for mail that arrived after the list was taken. Hover it for
  the senders.
- The Accent option's tooltip is right on every UI, not only under
  EllesmereUI.

## 1.22.0

### Improved

- **Minimap icon placement is one list**: Blizzard default (new, and the
  default for fresh installs: the icon sits where the stock mail indicator
  does), the four corners, Custom (shift-drag along the map edge) and Free
  (shift-drag anywhere). The detach checkbox is gone, and a drag updates the
  list.
- Left-clicking the minimap icon while your mailbox is open says so in chat
  instead of doing nothing.

## 1.21.0

### Improved

- **The mailbox memory window grew manners**: it opens beside the minimap,
  shows eight rows and scrolls the rest, resizes with a corner grip, and shows
  the real item tooltip where it can. It has its own switch in the minimap
  card, on by default.
- **Minimap icon placement is three plain controls**: the position dropdown, a
  "Detach from minimap" checkbox, and a new "Lock position" checkbox that
  stops shift-drag.
- **The attach option is called "Right-click attaches items"**, with a
  one-sentence tooltip.

## 1.20.0

### New

- **Left-click the minimap icon to see what your mailbox held, from
  anywhere.** Postbox remembers your inbox as you last saw it: sender,
  subject, gold, C.O.D. or items, and time left. It says when you looked,
  tells you when new mail has arrived since, and greys mail that has run out.
  Nothing runs while you play.

## 1.19.1

### Fixed

- "Attach from the Mail tab" did not work: the game switched it off a moment
  after the mailbox opened, so a right-clicked bag item was used instead of
  attached.
- The textures from 1.18.1 matched neither a clean install nor a UI pack.
  Postbox draws Blizzard's own art again, so it matches whichever you have.

## 1.19.0

### New

- **The minimap icon can leave the minimap edge**: a "Detached" position lets
  shift-drag place it anywhere on screen. It still follows the minimap and
  can never be lost off-screen.

### Improved

- **The options open with a right-click on the minimap icon**, not a
  left-click.

## 1.18.1

### Improved

- **Postbox looks right under UI packs that replace the game's textures**
  (AtrocityUI, NaowhUI), instead of turning into a dark see-through shell.
- **Paying and deleting leave a receipt in chat**: "C.O.D. paid: 12g 50s",
  "Deleted: 8 mails".

### Fixed

- Clicking an attachment in a C.O.D. mail's preview could pay it without
  asking. It asks now, like the Collect button.
- Greying out unmailable bag items reset the tint another addon had given
  them.

## 1.18.0

### New

- **Right-click a bag item while reading mail and the window flips to Send
  with it attached.** While the mailbox is open, bag items answer to the mail.
  A new option, "Attach from the Mail tab" (on by default), turns it off.

### Improved

- The recipient, subject and message fields stop at the length the server
  accepts, so a long paste no longer fails the send.

### Fixed

- A confirmation dialog could act on the wrong mail if the inbox changed
  while it waited. Each one re-checks its mail when you accept.
- Bulk collection can never pay a C.O.D., even if the inbox changes mid-run.
- A subject you wrote, like "Ore (20) and bars (40)", could have its numbers
  rewritten. Only a count at the very end of a subject is touched now.

## 1.17.2

### Fixed

- Walking away mid-collection could mark mail as stuck when a retry would
  have taken it. Such a marker also clears itself once the mail is collected.

## 1.17.1

### Improved

- The "Remaining" note from 1.17.0 is gone again: the leftovers are ordinary
  mail the counts already show.

## 1.17.0

### Improved

- **Walking away from a run leaves a note you can see**: reopening the
  mailbox shows "Remaining: 4" beside any stuck line, until the rest is
  collected.

## 1.16.5

### Fixed

- Stuck-mail triangles came back after a relog only if a finished run had
  recorded them. They now come back however the mail got stuck.

## 1.16.4

### Improved

- A run that collected nothing leads with the problem alone: "Stuck: 1", not
  "Collected: 0 - Stuck: 1".

## 1.16.3

### Improved

- The "Last visit: N mails could not be taken" sentence is gone. After a
  relog, stuck mail wears its triangle and the usual "Stuck: N" line.

## 1.16.2

### Improved

- The run outcome has one colour per fact: Collected in green, Stuck in
  amber, Incomplete in red.

## 1.16.1

### Improved

- The Manage Recipients bundle sits on a quiet accent glow.

## 1.16.0

### Improved

- **The recipient popup shows the row Tab is holding**, and the mark moves as
  you cycle.
- **The Mail tab caption defaults to Nothing**, and its button names the mode
  you picked. Every dropdown marks its current choice.
- The Manage Recipients portrait lines up with the button beneath it, with a
  bigger bundle icon.

### Fixed

- The second Tab in the recipient field sometimes did nothing. Tab is two
  presses again: accept the completion, then step down the list.

## 1.15.1

### Fixed

- The options panel from 1.15.0 showed an error when opened.

## 1.15.0

### Improved

- The General card reads as two clean columns again, with a full-width "Mail
  tab caption" button.
- The bug-report window's close button matches the options panel's, and its
  report scrolls inside its box.

## 1.14.2

### Fixed

- With the minimap icon on under EllesmereUI, mail that arrived after a fresh
  login showed no icon.

## 1.14.1

### Improved

- **The run outcome reports the whole run**: "Collected: 12", or with
  "Stuck: 1" or "Incomplete: 3 left" beside it when something went wrong.
- `/postbox debug` includes the minimap icon's state.

## 1.14.0

### New

- **Choose the Mail tab's caption** in General: still to collect over total
  (the default), total only, a quiet dot while anything waits, or nothing.

### Improved

- **Stuck mail speaks with one voice**: "Stuck: N" everywhere, and hovering
  the status line lists which mails and what the game said.
- **The warning triangles survive a relog**, until the mail is collected,
  returned or expires.
- The icon picker sits flush with the preview.

## 1.13.1

### Improved

- The tab's count turns grey when nothing is left to collect.

### Fixed

- The Mail tab's caption was drawn twice, over itself, under a host skin.
- The long "Last visit" line ran under the window title. It is cut short now,
  with the full line on hover.

## 1.13.0

### Improved

- **The main tab is called Mail** and, at a mailbox, shows the inbox at a
  glance: "Mail (3/12)", still to collect over total.

## 1.12.0

### Improved

- Manage Recipients is translated into German, Spanish and Russian.

### Fixed

- On the stock Blizzard UI, the options panel's cards, the status band and the
  bug-report window had no background.
- "Last visit: N mails could not be taken" was wiped the moment the mailbox
  opened, so it never survived a relog.
- With the minimap icon on under EllesmereUI, EllesmereUI's mouseover button
  row flashed when mail arrived.
- The bug-report window closes on Escape and opens centred, and its copy
  boxes can no longer be edited by accident.
- Also: the icon picker's scroll bar keeps its track under host skins, and a
  retired icon style falls back to Letter everywhere.

## 1.11.4

### Improved

- The Send tab's recipient-manager button sits inside the right end of the
  recipient field, and typed text stops short of it.

## 1.11.3

### Improved

- The bug-report window uses the standard close button.

### Fixed

- Under host skins, the bundle icon did not show on the Manage Recipients
  button or on the Send tab's recipient-manager button.

## 1.11.2

### Improved

- The Send tab's recipient-manager button is a proper button with the bundle
  icon, and Manage Recipients shows the icon at full strength.
- The EllesmereUI mode line is centred, and a switched-off minimap card stops
  its preview pulse.

## 1.11.1

### Improved

- **Manage Recipients is a portrait button** with its live count, and a
  matching button sits at the right end of the Send tab's recipient field.
- The EllesmereUI note in the options is one quiet line, with the full
  explanation in its tooltip.

## 1.11.0

### New

- **Pulse**: the glow's slow breathe, on by default.

### Improved

- The minimap options are a 2x2 grid (Glow, Shadow, Accent, Pulse) beside the
  preview, on a ground where the shadow shows. All four preview live.
- Manage recipients is a tall button beside the General checkboxes, which
  makes the card a row shorter.
- The bug-report window has a proper little x to close it.

## 1.10.1

### Improved

- The minimap section is a compact block, three rows shorter: a larger
  preview with Accent, Glow and Shadow toggles beside it.
- "Accent colour" is just "Accent", and its tooltip says what it colours: the
  glow and any tintable icon style.

## 1.10.0

### New

- **Run memory.** Warning triangles and the Stuck count survive closing the
  mailbox, and a run that ended badly is remembered to your next visit:
  "Last visit: N mails could not be taken".

### Improved

- The icon picker shows the current icon large, wearing the live accent, glow
  and shadow.
- The bug-report window is opaque and holds a copyable report, and
  `/postbox debug` opens it from anywhere.

## 1.9.1

### Fixed

- The author reads egsherlock, matching GitHub and CurseForge.

## 1.9.0

### New

- **Shadow**: a soft dark shadow behind the minimap icon, beside Glow.

### Improved

- The icon picker's list shows every icon beside its name.
- The bug-report popup is a proper little window, movable and opaque, with the
  address selected so Ctrl+C is all it takes.

### Fixed

- EllesmereUI faded the picker's preview and the status band's green light.
- The version footer read "vv1.8.0".

## 1.8.0

### Improved

- The addon-list icon is the clean London Postbox.
- The icon picker is a live preview beside a full-width dropdown.
- The status band shows a green light and the version; click it for a
  bug-report popup with a copyable setup summary.

## 1.7.0

### New

- **Eight "clean" icon restyles**, each beneath its original in the picker.
  The pillar postbox is now **London Postbox**, and the flat glyphs are
  **Envelope minimal** and **Badge minimal**. The red, white and iron
  mailboxes are retired.

### Improved

- The icon picker scrolls, opens on your current choice, and is no longer
  see-through.
- The minimap checkbox sits on its section heading, and the footer says whose
  style is in use ("Options synced with EllesmereUI").

## 1.6.2

### Improved

- The pillar postbox is the addon-list icon.

## 1.6.1

### Improved

- Nine of the painted icons have cleaner edges.

## 1.6.0

### New

- **Fifteen more hand-painted minimap icons**: open letter, scroll, red, white
  and iron mailboxes, mail bag, satchel, quill and ink, stamped and weathered
  envelopes, letter bundle, pillar postbox, and stone, wooden and golden
  crests. Letter stack and Plate are retired, and Letter is the new default.

### Improved

- The minimap section's checkbox sits above its card, and unticking it greys
  the card out.

## 1.5.0

### New

- **Five hand-painted minimap icons**: Letter, Sealed letter, Parcel, Wax seal
  and Letter stack. The flat icons and Blizzard's envelope are still there.

### Improved

- The glow is the soft disc from 1.4.0 again; the halo read as an explosion
  in game.
- The options panel puts General, Minimap and Appearance on cards of their
  own.

## 1.4.1

### Improved

- The glow is a soft ring around the icon, so a tinted icon stays crisp.
- Accent colour is off by default for the minimap icon; the glow follows the
  accent either way.

## 1.4.0

### New

- **Three minimap icons drawn for small sizes**: Envelope, Plate and Badge,
  all tintable. "Minimal" and "Mailbox" are gone; if you used one, you now
  have Envelope.

### Improved

- The options panel has General, Minimap and Appearance headings, and a line
  at the bottom says which style is painting Postbox.

## 1.3.0

### Improved

- **With EllesmereUI's minimap, Postbox styles its mail icon instead of
  adding a second one**: your icon style, tint and glow, in EllesmereUI's
  place. Switch the option off and theirs is restored exactly.

## 1.2.0

### Improved

- The minimap mail icon sits inside the map edge, with a position dropdown:
  top right by default, any corner, or Custom by shift-drag.

### Fixed

- Under EllesmereUI, the minimap's mouseover button bar flickered when mail
  arrived, and its own mail icon popped up beside Postbox's. Mail already
  waiting at login can still show theirs until it is collected.

## 1.1.0

### New

- **Minimap mail icon**, off by default (in the options, or
  `/postbox minimap`). Postbox's own icon replaces the default new-mail
  indicator: four styles, four sizes, an optional accent tint, and a soft glow
  that pulses while mail waits. Shift-drag it along the rim. Switch it off and
  the default indicator comes back intact.

## 1.0.0

Initial public release.

### New

- **Collect**: the whole inbox on three tabs (Collect / Done / All), one-click
  category sweeps, and bulk collection that skips what the server refuses
  instead of stopping, and says so when a run cannot finish. Preview any mail
  without collecting it; mail the game will not hand over shows its reason.
- **Send**: name completion (Tab accepts, Tab cycles), recipients in Recent,
  Alts, Friends and Guild, favourites, and guidance on what will happen before
  you send.
- **Recipient manager** (`/postbox recipients`): search, sort, favourite,
  hide and annotate every name Postbox can offer.
- **Optional EllesmereUI and ElvUI skins** that follow your own settings;
  without either, Postbox uses its own theme.
- Five languages: English, Français, Deutsch, Español, Русский.
