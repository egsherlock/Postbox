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
  before the next is sent, items the server refuses are skipped instead of ending the
  run, and anything that genuinely can't be collected is reported in the game's own
  words rather than failing silently.
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

Three views — Collect, Done, All — with one-click sweeps for expired, sold, bought
and cancelled auction mail. Shift-click a mail to look inside without collecting;
hover an attachment for its real item tooltip. A finished run reports what it earned
and spent. Compact rows fit half again as many mails in the same window.

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

## Appearance

<img src="docs/screenshots/options.png" height="430" align="right" alt="The options panel" />

One panel behind the window's cog, and it wears whatever your window is wearing.

**Window style** picks who paints Postbox: your UI pack, Blizzard-native, or Postbox
Modern. A badge on the Appearance heading says which is happening — a green dot for
*Inheriting EllesmereUI settings*, a neutral one for *Overriding EllesmereUI* — so
the panel is never ambiguous about where the look is coming from.

**Border, border size and background opacity** belong to whichever style is painting.
Under a UI pack they default to matching it, so a change to your pack's borders or
transparency carries here without you touching anything. Postbox Modern brings its
own three.

The rest is behaviour: compact mail rows, tab mail counts, the Mail-tab caption
(counts, total, a dot, or nothing), click-to-open versus click-to-collect, window
grid docking, and the mail alerts — sound, flash, and whether the mailbox memory is
kept at all.

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
persistent `OnUpdate`: the only per-frame work in the addon happens while you are
actively dragging or resizing something, and it clears itself when you stop. Inbox
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
