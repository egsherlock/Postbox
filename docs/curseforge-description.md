# CurseForge / Wago listing

Everything needed to create the listings. **Part 1** is the project metadata —
name, summary, category, licence. **Part 2**, below the rule, is the description
body itself.

**Wago** takes Part 2 as markdown, as-is.

**CurseForge**'s editor accepts rich text and HTML, and images go through CF's own
media manager rather than by path. So: upload the banner and the eight screenshots
there first, paste Part 2, then replace each `> [screenshot: …]` marker with the
matching uploaded image. The markers are placement notes, not content.

---

## Part 1 — project metadata

### Project name

**Postbox — Modern Mailbox & Mail Manager**

Brand first so the name stays yours, then the two words people actually search
(`mailbox`, `mail`). "Manager" catches intent from people looking to *do* something
with their mail rather than just re-skin it; "Modern" separates it from the older
mail addons it will sit beside in results. Keep the URL slug plain: `postbox`.

Alternatives, if you'd rather:
- *Postbox — Mailbox Replacement & Bulk Mail* — heavier on "replacement" and
  "bulk", lighter on the manager side.
- *Postbox — Mail, Mailbox & Inbox Manager* — widest keyword net, reads more like
  a listing than a name.

### Summary

One sentence. It is the addon's whole pitch — CurseForge shows it on the search
card, Wago under the title, and most people never read further:

> A modern mailbox replacement that empties a full inbox in one click, completes
> every recipient as you type, and wears your UI.

Says what it is before what it does, so "mailbox" lands early for search, then the
three things a player actually feels: the bulk collect, the name completion, and it
not looking out of place.

Alternatives, by emphasis:
- *Function-first, warmer, weaker for search:* "One window that empties your mailbox
  in a click, remembers everyone you write to, and looks like the rest of your UI."
- *Widest keyword net, reads more like a list:* "Replaces the default mailbox with
  one window — bulk collect, auction-mail sweeps, recipient completion, right-click
  attach, and an optional minimap mail icon."

### Category

Primary: **Mail** — matches `## X-Category: Mail` in the .toc.

If CurseForge lets you add secondaries, **Map & Minimap** (the minimap icon is a real
feature, not a footnote) and **Auction & Economy** (the auction-mail sweeps) are both
honest fits. Do not add more than that; categories you only half-belong in cost you
credibility with the people who find you through them.

### Licence

**GNU General Public License version 3 (GPLv3)** in CF's licence dropdown — it
matches `LICENSE` and `## X-License` in the .toc. The repository is public, which is
what GPLv3 asks of you.

### Game versions

Retail only: 12.0.7 and 12.1.x. No Classic, Cata or MoP builds — do not tick them.

### Tags

`mail`, `mailbox`, `inbox`, `auction house`, `ui replacement`, `quality of life`,
`minimap`, `elvui`

---

## Part 2 — description body

> [screenshot: postboxbanner.png — full width, top of page]

**Postbox replaces the World of Warcraft mailbox with one window that opens where you
do.** It clears a full inbox in a single pass, remembers everyone you write to, and
tells you what your mailbox held even when you are nowhere near one.

No dependencies. No libraries. Nothing to configure — install it and open a mailbox.

> [screenshot: collect.png]

---

## Clear a full mailbox in one click

One button empties the box, and it does it carefully. Every command waits for the
server to confirm the last one, so nothing is lost to a burst of requests. An item
the game refuses — bags full, a unique you already carry — is skipped and marked with
the game's own reason, instead of ending the run or sitting there looking ignored. A
run that cannot finish says so; it never reports success it did not have.

Sweep buttons pick out just the expired auctions, just the sales, just what you
bought, just the cancellations. When the run finishes, chat tells you what it earned
and what it spent.

Shift-click any mail to read it without collecting it. Hover an attachment for the
real item tooltip. Turn on compact rows and half again as many mails fit in the same
window.

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

> [screenshot: recipientmanager.png]

---

## Know what is in the box without going to one

Left-click the minimap icon anywhere in the world and Postbox shows you what your
mailbox held the last time you opened it: who sent what, how much gold, what was
attached, how long each one has left.

It is honest about being a memory. The header says how long ago you looked, it tells
you when new mail has arrived since, and it never pretends to be live.

> [screenshot: mailboxmemory.png]

---

## A minimap icon worth keeping

Optional, and off until you ask for it. Replace the default "you have mail" indicator
with one of more than two dozen hand-painted styles at four sizes — on the minimap
rim or detached anywhere on screen, placed by shift-drag — with an accent tint, a
soft glow, and a flash when new mail arrives.

Hovering it tells you what has arrived since you last looked, what is waiting broken
down by sender, and what could not be collected.

Running EllesmereUI? Postbox restyles *their* mail icon in place rather than adding a
second one beside it. Switch the feature off and everything goes back exactly as it
was.

> [screenshot: minimapmailicon.png]

---

## It wears your UI

Using **EllesmereUI**? Postbox registers with its skinning API and follows your
profile — colours, font, borders, transparency — live, including mid-session profile
switches.

Using **ElvUI**? It matches your theme, WindTools borders included.

Using neither? Choose between the warm Blizzard-native look and **Postbox Modern**, a
flat, near-black, minimal style with its own border and transparency settings.

And if you run a UI pack but prefer Postbox's own look, you can simply say so — the
window style is yours either way. The options panel is plain about which is
happening: a green dot reads *Inheriting EllesmereUI settings* when Postbox is
wearing your pack's look, and a neutral one reads *Overriding EllesmereUI* when you
have chosen otherwise.

> [screenshot: defaultblizzard.png]
> [screenshot: postboxmodern.png]
> [screenshot: options.png]

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

## Slash commands

- `/postbox` — the help text
- `/postbox rm` — the recipient manager, from anywhere
- `/postbox minimap` — toggle the minimap icon
- `/postbox skin` — what UI pack was detected, and what is painting the window
- `/postbox debug` — a setup line to paste into a bug report

---

## Languages

English, Français, Deutsch, Español, Русский — complete, not partial, including
proper plural rules rather than a bolted-on "s".

Corrections and new languages are welcome on GitHub.

---

*Settings are account-wide. Retail 12.0.7–12.1.x. GPL v3.*
*Issues, source and contributions:* `https://github.com/egsherlock/Postbox`
