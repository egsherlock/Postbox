<p align="center">
  <img src="docs/postboxbanner.png" alt="Postbox" />
</p>

<p align="center">
  <b>A modern, lightweight replacement for the World of Warcraft mailbox.</b><br />
  Clear a full inbox in one click, see every character's mail from anywhere, and send without second-guessing.
</p>

<p align="center">
  Retail 12.0.7–12.1.x &nbsp;·&nbsp; no dependencies, no libraries &nbsp;·&nbsp;
  <a href="https://www.curseforge.com/wow/addons/postbox">CurseForge</a> &nbsp;·&nbsp;
  <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center">
  <img src="docs/media/collect.gif" width="420" alt="A full inbox collected in one click" />
</p>

## At a glance

| | |
|---|---|
| **Mail tab** | One-click collection with sweeps by kind, search and row selection, read mail folded away, and a History of everything collected. |
| **Mail Memory** | Every character's last-seen mailbox, from anywhere: searchable across characters, with warnings before mail expires. |
| **Send tab** | Names complete as you type, a line says what a send will do before it happens, and more than twelve items go out in one press. |
| **Recipients** | Recent correspondents, alts, friends (Battle.net included) and guild, with favourites and a manager window. |
| **Minimap** | An optional mail icon in two dozen styles, with a tooltip that answers "what is waiting?" |
| **Looks** | Follows EllesmereUI or ElvUI live, or runs Blizzard-native or its own flat Postbox Modern. |

## The Mail tab

<img src="docs/screenshots/mail.png" height="360" align="right" alt="The Mail tab" />

One inbox. Mail that still holds something comes first; read mail with nothing
left sits under a divider that folds it away and deletes it in one click. In a
long list the divider pins itself to the foot of the list until you scroll to it.
Options can move read mail to a Done tab instead, or delete each mail the moment
Postbox empties it.

- **Collection is serialised.** One server command in flight at a time, each
  confirmed before the next. The queue is built high index to low, so a mail the
  server deletes mid-run never shifts the ones still to come. Bag space is checked
  before anything is opened.
- **Sweeps by kind** (bought, sold, cancelled, expired, other, from your alts).
  Under a search or a shift/ctrl selection they act only on what is on screen.
- **Refusals are recorded, not skipped.** A mail the game will not hand over is
  marked with the game's own error text and counted in the title bar's
  `Stuck: N`, which also filters the list to just those mails.
- **Rows** are compact by default: gold, slots and time left in columns, in the
  order you choose. Crafting quality is read from the item link's own atlas.
- **Counts** mean one thing each: Inbox is everything in the box (the server's
  total, read mail included); each button is what it would collect.

<br clear="all" />

### History

<img src="docs/screenshots/history.png" height="260" align="right" alt="History" />

The clock beside Inbox lists what Postbox collected on this character, newest
first: when, from whom, what came out and what it was worth, with earned and
spent totals. A letter's text is kept too, so it can be read after the mail is
deleted. Seven days by default, up to thirty; at most 1,000 entries per character,
pruned for every character at login.

<br clear="all" />

## Mail Memory

<p align="center">
  <img src="docs/media/characters.gif" width="420" alt="Another character's mailbox, in the Mail tab" />
</p>

A snapshot of each character's inbox, taken as the mailbox closes (up to 100
mails). Away from a mailbox it opens from the minimap icon, the minimap's addon
menu or `/postbox mail`; at a mailbox, the character picker beside the search box
shows any character's box right in the Mail tab. The toggle inside the search box
searches every character at once.

- **Arrivals are detected, not guessed:** the pending-mail event (guarded against
  login and close churn), the unread flag flipping, the latest-senders line
  changing, and the auction house's own sold / expired / bought notices, which
  name the item.
- **Warnings** name any character with mail under three days from expiring, or
  with mail known to be on its way and no mailbox visit in over three weeks: in
  the minimap tooltip, and once in chat at login.

## Sending

<p align="center">
  <img src="docs/media/queue.gif" width="420" alt="Every stack attached, the rest queued" />
</p>

- **Names complete in place** from recent correspondents, alts, friends and guild.
  Tab walks the suggestions, Enter takes the whole name, realm included. Case
  folding is byte-exact for Latin-1 and Cyrillic, so a lowercase "ив" finds Иван.
- **A guidance line** says whether the mail arrives instantly or in an hour, and
  whether a cross-realm send can carry what is attached. It advises; it never
  blocks.
- **Past twelve items**, right-clicks keep queuing; one press posts the rest as
  further mails to the same person, after a single confirmation of how many mails,
  items and postage. Alt+right-click attaches every stack of an item; right-click
  "Attachments" takes everything out again.
- An unsent draft survives closing the mailbox.

## Recipients and the minimap

<p align="center">
  <img src="docs/screenshots/recipientmanager.png" height="250" alt="The recipient manager" />
  <img src="docs/screenshots/minimapmailicon.png" height="250" alt="The minimap icon and its tooltip" />
</p>

The recipient manager (`/postbox rm`, works anywhere) searches, sorts,
favourites, hides and annotates every name Postbox can suggest. The minimap icon
is optional: two dozen hand-painted styles at four sizes, on the minimap's rim or
anywhere on screen. Under EllesmereUI's minimap it restyles *their* mail button in
place rather than adding a second one.

## Looks and options

<p align="center">
  <img src="docs/screenshots/postboxmodern.png" height="280" alt="Postbox Modern" />
  <img src="docs/screenshots/options.png" height="280" alt="The options panel" />
</p>

EllesmereUI is followed through its skinning API: accent, fonts and opacity,
including after a profile switch. ElvUI is matched, WindTools borders included. Without either,
choose Blizzard-native or Postbox Modern, and you can choose Postbox's own look
even with a UI pack installed. One options panel covers rows, the Mail tab, read
mail and History, the Send tab, alerts, the window, the minimap icon and Mail
Memory.

## How it's built

- **No libraries.** `Lib/` is a small hand-rolled foundation: saved-variable
  store, event bus, string and money formatting, an inventory-lock overlay, and
  three UI primitives. No Ace, no LibStub.
- **Taint-clean by construction.** Postbox never touches Blizzard's mail code. It
  draws its own window and calls the mail API directly. The one residual case is
  documented in [COMBAT_TAINT.md](COMBAT_TAINT.md).
- **Idle means idle.** No repeating timers. The five per-frame handlers each belong
  to a gesture (a drag, a resize, a reorder, the message box following your
  cursor) and remove themselves when it ends. Inbox updates are drained once per frame, and searches over remembered
  mail and History are cached.
- **One skin contract, three skins.** A skin claims `ns.Skin` at login and answers
  `Apply`/`Refresh` over tagged frames. See
  [ELLESMEREUI_SKINNING.md](ELLESMEREUI_SKINNING.md).

## Languages

English, Français, Deutsch, Español, Русский, 简体中文 and 繁體中文, complete rather
than partial, with plural rules per language (Russian's one/few/many included).
Both Chinese translations are by **samuelbears**. Corrections and new languages are
welcome: strings live in `Core/Locales.lua`.

## Install and commands

From CurseForge or any addon manager, or copy the `Postbox` folder into
`World of Warcraft\_retail_\Interface\AddOns\`. Settings are account-wide.

| Command | |
|---|---|
| `/postbox` | Help |
| `/postbox mail` | Mail Memory: every character's mailbox |
| `/postbox rm` | The recipient manager |
| `/postbox minimap` | Toggle the minimap icon |
| `/postbox skin` | Which UI was detected and what is painting the window |
| `/postbox debug` | A copyable report for bug reports (no character names, no addon list) |

Licensed under [GPL v3](LICENSE).
