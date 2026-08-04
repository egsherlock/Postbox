# Listing metadata

The values Postbox is published under, as a record. CurseForge is already set up
with these — the reason to keep the file is that the same answers are needed again
for Wago, WoWInterface, or any future listing, and they should not be re-invented
slightly differently each time.

For the release process — what to update when, and how to write the changelog — see
[RELEASING.md](RELEASING.md). For the description body, see
[curseforge-listing.md](curseforge-listing.md): that file is the paste, and nothing
but the paste.

| | |
|---|---|
| Name | **Postbox — Modern Mailbox & Mail Manager** |
| Slug | `postbox` |
| Category | **Mail** (secondaries: Map & Minimap, Auction & Economy) |
| Licence | **GNU General Public License version 3 (GPLv3)** |
| Game versions | Retail **12.0.7** and **12.1.x** only — no Classic flavours |
| Tags | `mail`, `mailbox`, `inbox`, `auction house`, `ui replacement`, `quality of life`, `minimap`, `elvui` |
| CurseForge project id | `1639171` (also in `Postbox.toc`) |
| Automatic packaging | **Off.** The GitHub Action builds and uploads; two packagers means two competing files per tag. |

## Summary

Kept identical to `## Notes` in `Postbox.toc`, so the pitch reads the same in the
in-game AddOns list, on CurseForge and on Wago. 239 of the 250 characters allowed:

> A modern mailbox replacement: clear a full inbox in one click or just the mail you
> choose, complete any recipient as you type, right-click to attach, and see what is
> waiting without visiting a mailbox. Wears your ElvUI or EllesmereUI look.

Says what it is before what it does, so "mailbox" lands early for search. Then four
things a player would actually notice, and **both UI packs by name** — people search
for what fits their setup, and ElvUI goes first because far more people run it.

**"Or just the mail you choose", not "sweeps your auction mail".** An earlier draft
said the latter and it was an overstatement: the sweeps filter by KIND — expired,
sold, bought, cancelled, other — which is mostly auction mail but is not limited to
it, and "All mail" is a sweep too. Claiming a narrower feature than the one that
exists is a strange way to lose people.

The minimap icon and the memory are both left out for space. The icon is the most
visible thing in the screenshots so the listing sells it regardless; the memory is
covered by "see what is waiting without visiting a mailbox", which describes the
benefit without spending words naming the mechanism.

**If the summary changes, it changes in three places:** here, `Postbox.toc`, and the
CurseForge/Wago listing fields.

## Images

The description body uses absolute `raw.githubusercontent.com` URLs pointing at this
repository on `main`. That is what lets the same markdown work on CurseForge, on Wago
and on GitHub — a relative path resolves on GitHub and nowhere else.

They depend on the repository staying **public**. If it ever goes private the listing
images break everywhere at once; CurseForge's own media manager is the fallback.
