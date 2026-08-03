# CurseForge / Wago project description

Paste-ready source for the CurseForge and Wago listings. CF's editor accepts
rich text/HTML; images are attached through CF's own media manager, so upload
`docs/postboxbanner.png` there and place it at the top, then the screenshots
(same set as the README) between sections. Wago takes this markdown as-is.

Suggested project title (searchable, mail keywords up front):
**Postbox — Modern Mailbox & Mail Replacement**

---

**Postbox is a modern, lightweight replacement for the default mailbox** — one
window that opens automatically at any mailbox, clears a full inbox in one
pass, and remembers everyone you write to.

No dependencies. Nothing to configure. Install it and open a mailbox.

## Collect a full mailbox in one click — safely

Bulk collection that treats your mail with respect: every server command is
confirmed before the next is sent, refused items are skipped instead of ending
the run, and a run that cannot finish says so rather than reporting success.
One-click sweeps for expired, sold, bought and cancelled auction mail. When a
collection finishes, chat tells you what it earned and what it spent.

Shift-click any mail to look inside without collecting it. Hover an attachment
for the real item tooltip. And when the game refuses to hand something over —
bags full, unique item — the mail is marked with the game's own reason instead
of sitting there looking ignored.

## Send without second-guessing

Start typing a recipient and the name completes in place — Tab accepts it. Your
recent correspondents, alts, friends (Battle.net included) and guildmates are
one click away; favourite the ones you mail constantly. A guidance line says
what will happen *before* you send — instant or delayed, and whether a
cross-realm send can carry what you attached. Nothing is ever blocked: Postbox
advises, you decide. A failed send keeps your draft.

Right-click an item in your bags — even while reading mail — and the window
flips to Send with it already attached. While you compose, unmailable items
wear a padlock in your bags, so what can go is visible at a glance.

The window grows as your message does, a line at a time, and shrinks back as
you delete — your saved size is never touched.

## A recipient manager

`/postbox recipients` — from anywhere, no mailbox needed. Search, sort,
favourite, hide and annotate every name Postbox can offer. Hidden means hidden:
a hidden name vanishes from every suggestion, and this window is where you
bring it back.

## A minimap mail icon worth keeping

Optional — replace the default "you have mail" indicator with one of 20+
hand-painted styles at four sizes, placed anywhere on the minimap rim by
shift-drag, with an accent tint, a soft glow and a slow pulse while mail
waits. Under EllesmereUI's minimap it restyles their icon in place rather
than adding a second one, and everything restores cleanly when switched off.

## Wears your UI

Using **EllesmereUI**? Postbox registers with its skinning API and follows your
profile's colours, font, border and transparency — live, including mid-session
profile switches. Using **ElvUI**? It matches your theme, WindTools borders
included. Using neither? It has its own clean look. `/postbox skin` shows what
was detected.

## Light on purpose

Postbox never touches Blizzard's own mail code — no hooks into protected
frames, no taint, nothing that can break the default UI in combat. Refreshes
are coalesced, work stops while panels are hidden, and there are no libraries
to load.

## Languages

English, Français, Deutsch, Español, Русский — corrections and new languages
welcome on GitHub.

---

*Settings are account-wide. GPL v3. Issues and contributions:*
`https://github.com/egsherlock/Postbox`
