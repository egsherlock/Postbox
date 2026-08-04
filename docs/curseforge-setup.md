# CurseForge / Wago listing — setup

The fields you fill in when creating the project: name, summary, category, licence,
game versions, tags.

**The description body is not here.** It is `curseforge-listing.md`, which is that
file and nothing else — open it, select all, paste. Kept separate so there is never
a question about where the notes end and the copy begins.

Both CurseForge and Wago take it as markdown, as-is. Its images are absolute
`raw.githubusercontent.com` URLs pointing at this repository on `main`, which is
what makes that work: a relative path like `docs/screenshots/collect.png` resolves
on GitHub and nowhere else, so pasting one into either site gives a broken image.
All nine were confirmed serving 200 after the repository went public.

If you would rather not depend on GitHub serving them, CurseForge's own media
manager works too: upload the files there and swap each `![…](https://raw…)` for
the uploaded copy. Same images either way — only a question of who hosts them.

---

## Project metadata

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

One sentence, 250 characters to spend. It is the addon's whole pitch — CurseForge
shows it on the search card, Wago under the title, and most people never read
further. This is also the `## Notes` line in `Postbox.toc`, so the two stay in step:

> A modern mailbox replacement that empties a full inbox in one click, completes
> every recipient as you type, and remembers what was waiting so you can check from
> anywhere. Wears your ElvUI or EllesmereUI look.

234 characters. Says what it is before what it does, so "mailbox" lands early for
search. The budget then buys three things a shorter line cannot afford: **auction
mail** (heavily searched, and the sweeps are a real feature), **the memory** — the
one thing nothing else does, so it is worth the words — and **naming both UI packs**,
because people search for what fits their setup. ElvUI first: far more people run it.

The minimap icon is deliberately left out. It is the most visible thing in the
screenshots, so the listing sells it regardless, whereas the memory is invisible
until somebody reads about it.

### Category

Primary: **Mail** — matches `## X-Category: Mail` in the .toc.

If CurseForge lets you add secondaries, **Map & Minimap** (the minimap icon is a real
feature, not a footnote) and **Auction & Economy** (the auction-mail sweeps) are both
honest fits. Do not add more than that; categories you only half-belong in cost you
credibility with the people who find you through them.

### Licence

**GNU General Public License version 3 (GPLv3)** in CF's licence dropdown — it
matches `LICENSE` and `## X-License` in the .toc. GPLv3 requires the source to be
available, which the public repository satisfies.

### Game versions

Retail only: 12.0.7 and 12.1.x. No Classic, Cata or MoP builds — do not tick them.

### Tags

`mail`, `mailbox`, `inbox`, `auction house`, `ui replacement`, `quality of life`,
`minimap`, `elvui`

---
