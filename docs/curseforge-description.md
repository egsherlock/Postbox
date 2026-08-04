# CurseForge / Wago project description

Paste-ready source for the CurseForge and Wago listings.

**Wago** takes this markdown as-is — everything below the rule.

**CurseForge**'s editor accepts rich text and HTML, and images go through CF's own
media manager rather than by path. So: upload `docs/postboxbanner.png` and the seven
screenshots there first, paste the text below, then drop each image in at the marker
that names it. The `> [screenshot: …]` lines are placement markers, not content —
replace each one with the uploaded image.

Suggested project title (searchable, mail keywords up front):
**Postbox — Modern Mailbox & Mail Replacement**

Suggested tags: `mail`, `mailbox`, `inbox`, `auction house`, `ui replacement`,
`quality of life`, `elvui`, `minimap`

---

> [screenshot: postboxbanner.png — full width, top of page]

**Postbox replaces the World of Warcraft mailbox with one window that opens where
you do.** It clears a full inbox in a single pass, remembers everyone you write to,
and tells you what your mailbox held even when you are nowhere near it.

No dependencies. No libraries. Nothing to configure — install it and open a mailbox.

---

## Clear a full mailbox in one click

One button empties the box, and it does it carefully. Every command waits for the
server to confirm the last one, so nothing is lost to a burst of requests. An item
the game refuses — bags full, a unique you already carry — is skipped and marked
with the game's own reason, instead of ending the run or sitting there looking
ignored. A run that cannot finish says so; it never reports success it did not have.

Sweep buttons pick out just the expired auctions, just the sales, just what you
bought, just the cancellations. When the run finishes, chat tells you what it earned
and what it spent.

Shift-click any mail to read it without collecting it. Hover an attachment for the
real item tooltip. Turn on compact rows and half again as many mails fit in the same
window.

> [screenshot: collect.png]

---

## Send without second-guessing

Start typing a name and it completes in place — Tab accepts it. Your recent
correspondents, your alts, your friends (Battle.net included) and your guild are one
click away, and the ones you mail constantly get a star.

Before you send, a line tells you what is about to happen: whether the mail arrives
instantly or in an hour, and whether a cross-realm send can actually carry what you
have attached. Nothing is ever blocked. Postbox tells you, and you decide. If a send
fails, your draft is still there.

Right-click an item in your bags — even while you are reading a mail — and the window
flips to Send with it already attached. While you compose, anything that cannot be
mailed wears a padlock in your bags, so what can go is obvious at a glance.

The window grows a line at a time as your message does, and shrinks back as you
delete. Your saved window size is never touched.

> [screenshot: send.png]

---

## A recipient manager

`/postbox rm` opens it from anywhere — no mailbox needed.

Search, sort, favourite, hide and annotate every name Postbox can offer you. Hidden
means hidden: the name disappears from every suggestion everywhere, and this window
is where you bring it back. Categories mean exactly what they say — Recent is in
recency order, Guild is your guild, Friends includes Battle.net.

> [screenshot: recipients.png]

---

## Know what is in the box without going to one

Left-click the minimap icon anywhere in the world and Postbox shows you what your
mailbox held the last time you opened it: who sent what, how much gold, what was
attached, how long each one has left.

It is honest about being a memory. The header says how long ago you looked, it tells
you when new mail has arrived since, and it never pretends to be live.

> [screenshot: memory.png]

---

## A minimap icon worth keeping

Optional, and off until you ask for it. Replace the default "you have mail"
indicator with one of more than two dozen hand-painted styles at four sizes — on the
minimap rim or detached anywhere on screen, placed by shift-drag.

An accent tint, a soft glow, and a flash when new mail arrives. Hovering it tells you
what has arrived since you last looked, what is waiting broken down by sender, and
what could not be collected.

Running EllesmereUI? Postbox restyles *their* mail icon in place rather than adding a
second one beside it. Switch the feature off and everything goes back exactly as it
was.

> [screenshot: minimap.png]

---

## It wears your UI

Using **EllesmereUI**? Postbox registers with its skinning API and follows your
profile — colours, font, borders, transparency — live, including mid-session profile
switches.

Using **ElvUI**? It matches your theme, WindTools borders included.

Using neither? Choose between the warm Blizzard-native look and **Postbox Modern**, a
flat, near-black, minimal style with its own border and transparency settings.

And if you run a UI pack but prefer Postbox's own look, you can say so — the window
style is yours either way. The options panel is plain about which is happening: a
green dot reads "Inheriting EllesmereUI settings" when Postbox is wearing your pack's
look, and a neutral one reads "Overriding EllesmereUI" when you have chosen
otherwise.

> [screenshot: options.png]
> [screenshot: modern.png]

---

## Light on purpose

Postbox never touches Blizzard's own mail code. It draws its own window and talks to
the mail API directly, so there are no hooks into protected frames and nothing it
does can break the default UI in combat.

It also does nothing when nothing is happening: no repeating timers of any kind, and
the only per-frame work in the whole addon happens while you are actively dragging or
resizing something. Away from a mailbox it costs you a handful of event handlers that
return immediately.

---

## Languages

English, Français, Deutsch, Español, Русский — complete, not partial, including
proper plural rules rather than a bolted-on "s".

Corrections and new languages are welcome on GitHub.

---

*Settings are account-wide. Retail 12.0.7–12.1.x. GPL v3.*
*Issues, source and contributions:* `https://github.com/egsherlock/Postbox`
