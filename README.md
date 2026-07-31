<p align="center">
  <img src="postboxbanner.png" alt="Postbox" />
</p>

**Postbox replaces the default World of Warcraft mailbox** with something faster,
safer and friendlier — one window that opens automatically at any mailbox, clears a
full inbox in one pass, and remembers everyone you write to.

For retail (Midnight, 12.0.x–12.1). No dependencies, nothing to configure — install
it and open a mailbox.

## What it does

- **Empties a full mailbox in one click** — and does it safely. Every server command
  is confirmed before the next is sent, items the server refuses are skipped instead
  of ending the run, and if something genuinely can't be collected, Postbox tells
  you why in the game's own words instead of failing silently.
- **Knows who you mail.** Start typing a name and it completes in place — Tab
  accepts it. Your recent correspondents, alts, friends and guildmates are one
  click away, favourites get a star, and a manager window lets you curate the lot.
- **Stays out of your way.** Move it, resize it, let it grow as you type a longer
  message. It follows your EllesmereUI or ElvUI look automatically if you use one,
  and looks just as sharp without either.

## Screenshots

| | |
|---|---|
| ![The Collect tab](docs/screenshots/collect.png) | ![The Send tab](docs/screenshots/send.png) |
| *Collect: the whole inbox, one pass* | *Send: completion, favourites, guidance* |
| ![The recipient manager](docs/screenshots/recipients.png) | ![Skinned by EllesmereUI](docs/screenshots/skinned.png) |
| *The recipient manager* | *Wearing your EllesmereUI look* |

## The details, if you want them

**Collecting.** Three views — Collect, Done, All — with one-click sweeps for
expired, sold, bought and cancelled auction mail. Shift-click any mail to look
inside it without collecting; hover an attachment for its real item tooltip. A
finished run reports what it earned and spent in chat. A compact-rows option fits
half again as many mails in the same window.

**Sending.** Attachment slots, gold and C.O.D., with a guidance line that says what
will happen to a mail *before* you send it — instant or delayed, and whether a
cross-realm send can carry what you attached. Nothing is ever blocked; Postbox
advises, you decide. A failed send keeps your draft.

**Recipients.** Categories mean what they say: Recent is in recency order, Guild is
your guild, Friends includes Battle.net. Right-click favourites a name anywhere;
hiding a name removes it from every suggestion. The manager
(`/postbox recipients`, works away from any mailbox) does the housekeeping:
search, sort, favourite, hide, annotate.

**Skins.** With [EllesmereUI](https://github.com/EllesmereGaming/EllesmereUI),
Postbox registers with its skinning API (8.6.8+; a built-in fallback covers older
versions) and follows your profile's colours, font, border and transparency — live.
With [ElvUI](https://www.tukui.org/elvui), it matches your ElvUI theme. With
neither, it uses its own clean look. `/postbox skin` shows what was detected.

## Installation

From CurseForge or your addon manager — or manually: copy the `Postbox` folder into
`World of Warcraft\_retail_\Interface\AddOns\` and enable it in the AddOns list.

## Languages

English, Français, Deutsch, Español, Русский. Corrections and new languages are
welcome — strings live in `Core/Locales.lua` and fall back to English per key, so
partial contributions are safe.

## For the curious

| | |
|---|---|
| [CHANGELOG.md](CHANGELOG.md) | What changed, in plain words. |
| [ELLESMEREUI_SKINNING.md](ELLESMEREUI_SKINNING.md) | The EllesmereUI integration, in depth. |
| [COMBAT_TAINT.md](COMBAT_TAINT.md) | The in-combat mailbox taint story. |

Licensed under [GPL v3](LICENSE).
