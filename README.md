<p align="center">
  <img src="docs/postboxbanner.png" alt="Postbox" />
</p>

**A modern, lightweight replacement for the World of Warcraft mailbox.** One window
that opens at any mailbox, clears a full inbox in one pass, and remembers everyone
you write to.

Retail only (12.0.7–12.1.x). No dependencies, no libraries, nothing to configure —
install it and open a mailbox.

<p align="center">
  <img src="docs/screenshots/collect.png" height="330" alt="The Collect tab" />
  <img src="docs/screenshots/send.png" height="330" alt="The Send tab" />
</p>
<p align="center">
  <em>A full inbox cleared in one pass &nbsp;·&nbsp; composing, with completion and guidance</em>
</p>

## What it does

- **Empties a full mailbox in one click, safely.** Every server command is confirmed
  before the next is sent, bag space is checked before anything is opened, and items
  the game refuses are counted and explained in its own words rather than skipped
  quietly.
- **Keeps the books.** A running total of what a run earned and what it spent —
  proceeds, postage and C.O.D. together.
- **Knows who you mail.** Names complete in place as you type — Tab accepts. Recent
  correspondents, alts, friends (Battle.net included) and guildmates are one click
  away, favourites get a star, and a manager window curates the lot.
- **Attaches items the moment you click them.** Right-click anything in your bags,
  even while reading mail, and the window flips to Send with it attached. Unmailable
  items wear a padlock in your bags while you compose.
- **Remembers what was in the box.** Left-click the minimap icon anywhere in the
  world to see what your mailbox held when you last opened it — with an honest
  "last seen 2 h ago" header. It never pretends to be live.
- **Replaces the minimap mail icon**, if you want it to — more than two dozen
  hand-painted styles at four sizes, on the map edge or detached anywhere on screen.
- **Wears your UI.** EllesmereUI and ElvUI are followed live; without either, choose
  Blizzard-native or the flat **Postbox Modern**. You can pick Postbox's own look
  even when a UI pack is installed.

<p align="center">
  <img src="docs/screenshots/recipientmanager.png" height="250" alt="The recipient manager" />
  <img src="docs/screenshots/mailboxmemory.png" height="250" alt="Mailbox memory" />
</p>
<p align="center">
  <em>Every name you can write to, curated &nbsp;·&nbsp; what the box held, hours later</em>
</p>

## Collecting

Three views — Collect, Done, All — with one-click sweeps that pick out a single kind
of mail: expired, sold, bought, cancelled, or everything else. Shift-click a mail to
look inside without collecting; hover an attachment for its real item tooltip.
Compact rows fit half again as many mails in the same window.

A banner under the list keeps a running **total earned and total spent** — proceeds,
postage and C.O.D. charges — and the finished run repeats it in chat.

**Bag space is checked before the run starts.** If nothing will fit, Postbox says so
and stops before a single mail is marked read; if only part of it fits, it offers to
collect exactly that much and says how many. The offer is verified by fingerprint
when you accept, so a mailbox that reindexes while the dialog is open still collects
the mail the dialog described.

When the game refuses an item — you already have one, it is unique, you cannot carry
more — that mail is **marked and counted rather than skipped quietly**. The title bar
keeps a `Stuck: 2` tally, the row carries the reason, and where the game supplied one
Postbox quotes it instead of guessing. The count follows through to the mailbox
memory, so it is still there hours later.

## Sending

Attachment slots, gold and C.O.D., with a guidance line that says what will happen
*before* you send — instant or delayed, and whether a cross-realm send can carry what
you attached. Nothing is ever blocked: Postbox advises, you decide. A failed send
keeps your draft. The window grows as your message does and shrinks back as you
delete, without touching your saved size.

## Recipients

Categories mean what they say: Recent is in recency order, Guild is your guild,
Friends includes Battle.net. Right-click favourites a name anywhere; hiding one
removes it from every suggestion. The manager (`/postbox rm`, works away from any
mailbox) does the housekeeping: search, sort, favourite, hide, annotate.

## The minimap icon

<img src="docs/screenshots/minimapmailicon.png" height="235" align="right" alt="The minimap icon and its tooltip" />

Optional, and off until you ask for it. It replaces the default "you have mail"
indicator with one of more than two dozen hand-painted styles, at four sizes, placed
by shift-drag on the minimap rim or detached anywhere on screen — with an accent
tint, a soft glow, and a flash when new mail arrives.

Hovering it says what has arrived since you last looked, what is waiting broken down
by sender, and what could not be collected. Under EllesmereUI's minimap it restyles
*their* icon in place rather than adding a second one beside it, and switching the
feature off restores everything exactly as it was.

<br clear="all" />

## Settings

<img src="docs/screenshots/options.png" height="500" align="right" alt="The options panel" />

One panel, from the cog in the title bar or a right-click on the minimap icon.
Nothing in it is required reading — Postbox is meant to work before you open it — but
it is where the window becomes yours. In the panel's own order:

**General.** Compact mail rows, which fit half again as many mails on screen. Mail
counts on the tabs. Whether the All view is offered beside Collect and Done. Whether
a left-click opens a mail or collects it, and the Mail tab's caption: counts, a
running total, a single dot, or nothing at all. The recipient manager opens from
here too.

**Mail alerts.** A sound when mail arrives, a flash on the minimap icon, and whether
the mailbox memory is kept at all.

**Appearance.** **Window style** picks who paints Postbox: your UI pack,
Blizzard-native, or Postbox Modern. A badge on that heading says which is happening —
a green dot for *Inheriting EllesmereUI settings*, a neutral one for *Overriding
EllesmereUI* — so it is never ambiguous where the look is coming from. **Border,
border size and background opacity** belong to whichever style is painting; under a
UI pack they default to matching it, so a change to your pack's borders or
transparency carries here untouched, and Postbox Modern brings its own three.

**Minimap.** The icon on or off, its style from more than two dozen, its size, where
it sits, and whether it takes your accent colour, a glow, a shadow or a pulse while
mail waits.

<br clear="all" />

## Choose your look

The screenshots above are Postbox following EllesmereUI. Without a UI pack — or with
one, if you'd rather — it has two looks of its own:

<p align="center">
  <img src="docs/screenshots/defaultblizzard.png" height="300" alt="The Blizzard-native style" />
  <img src="docs/screenshots/postboxmodern.png" height="300" alt="Postbox Modern" />
</p>
<p align="center">
  <em>Blizzard-native, warm and familiar &nbsp;·&nbsp; Postbox Modern, flat and near-black</em>
</p>

## Slash commands

| | |
|---|---|
| `/postbox` | The help text. |
| `/postbox rm` | The recipient manager (also `recipients`). |
| `/postbox minimap` | Toggle the minimap icon. |
| `/postbox skin` | What host UI was detected, and which skin claimed the window. |
| `/postbox debug` | A setup line to paste into a bug report. |

## How it's built

**No libraries.** `Lib/` is a small hand-rolled foundation — saved-variable store,
event bus, string and formatting helpers, an inventory-lock overlay, and three UI
primitives (theme, window, dropdown). Nothing is embedded, so there is no Ace, no
LibStub, and no version negotiation with whatever else you have installed.

**Taint-clean by construction.** Postbox never touches Blizzard's mail code. It draws
its own window and talks to the mail API directly, so no protected frame is hooked
and no execution path of ours can taint one. The one residual case — the default
`MailFrame` on a second in-combat open — is documented in
[COMBAT_TAINT.md](COMBAT_TAINT.md) rather than papered over.

**Nothing runs when nothing is happening.** No repeating timers of any kind, and no
persistent `OnUpdate`: the four that exist are each scoped to a gesture — minimap
drag, window resize, dropdown scrollbar drag, and the compose box's cursor-follow,
which clears itself on the first frame it runs. Inbox
refreshes are marked and drained once per frame rather than per event, the chatty
social events are registered only while the compose tab is visible, and mailbox
memory writes saved variables once per visit.

**One skinning contract, three skins.** A skin claims `ns.Skin` at login and answers
`Apply`/`Refresh` over tagged children, so every window that knows how to be skinned
is skinnable by all three for free. EllesmereUI is followed through its own API
(8.6.8+, with a fallback for older builds) including live profile switches; ElvUI
matches your theme, WindTools borders included; Postbox Modern is a first-party flat
skin on the same contract. See [ELLESMEREUI_SKINNING.md](ELLESMEREUI_SKINNING.md)
for the integration in depth.

**Blizzard's dropdown and menu APIs are deliberately avoided** — a known taint vector
from a mail window. Postbox rolls its own.

## Languages

English, Français, Deutsch, Español, Русский — complete, not partial. Strings live in
`Core/Locales.lua` and fall back to English per key, so corrections and new languages
are safe to contribute piecemeal. Counted strings are declared as plural families
with per-locale rules (Russian selects one/few/many; French counts zero as one)
rather than by gluing an "s" on the end.

## Installation

From CurseForge, Wago or your addon manager — or manually: copy the `Postbox` folder
into `World of Warcraft\_retail_\Interface\AddOns\` and enable it in the AddOns list.

Settings are account-wide.

## For the curious

| | |
|---|---|
| [CHANGELOG.md](CHANGELOG.md) | What changed, in plain words. |
| [ELLESMEREUI_SKINNING.md](ELLESMEREUI_SKINNING.md) | The EllesmereUI integration, in depth. |
| [COMBAT_TAINT.md](COMBAT_TAINT.md) | The in-combat mailbox taint story. |

Licensed under [GPL v3](LICENSE).
