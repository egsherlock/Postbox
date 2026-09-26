# Working on Postbox

Postbox is maintained by egsherlock. These are the project's conventions.

## Commits

Commit as the maintainer:

```
git config user.name  "egsherlock"
git config user.email "95516063+egsherlock@users.noreply.github.com"
```

Check it before the first commit in a new environment; a fresh clone does not
inherit it. The account was renamed from `Sherlockell`; the id `95516063` is
what GitHub attributes by, so older commits under that name are the same
author.

Commit messages, tags, release notes, changelog entries and pull request text
are written in the maintainer's voice, with no `Co-Authored-By:` or session
trailers. This applies whatever the tooling's own defaults are.

## Workflow

- **Commit straight to `main`.** No feature branches, no pull requests for our
  own work. PRs are for outside contributors who cannot push here.
- **Offer a local test before any tag.** Nothing ships without the option of
  swapping the changed files into the live WoW install and `/reload`-ing first.
  A session on the maintainer's own machine copies them into
  `World of Warcraft\_retail_\Interface\AddOns\Postbox\` directly; a cloud
  session cannot reach that folder and hands the files over instead.
- **A release is a tag, and only a tag.** Merging to `main` builds nothing and
  uploads nothing. `.github/workflows/release.yml` fires on `v*` only.

## Version numbers

The line is `1.x.y` and `x` is past 9 — v1.38.0, v1.39.0. **The next minor is
v1.40.0, never v1.4.0.** Addon managers compare these numerically, so 1.4.0
reads as *older* than 1.39.0 and the update is never offered.

## Before a tag

`.dev/RELEASING.md` is the checklist and it is the authority. The two items
easiest to forget, because both are player-facing and neither is in the code:

- `CHANGELOG.md` — what CurseForge, Wago and WowUp show someone deciding
  whether to update. Voice rules are in the checklist; lead with the effect.
- `docs/curseforge-listing.md` — the CurseForge description. It reaches far
  more people than `README.md` does.

## House rules worth knowing

- **No libraries.** `Lib/` is hand-rolled. No Ace, no LibStub, nothing embedded.
- **Locales are complete, not partial** — seven blocks in `Core/Locales.lua`, and
  a new user-facing string is added to all of them.
- **Postbox never touches Blizzard's mail code.** Read `COMBAT_TAINT.md` before
  changing anything near `MailFrame`, the UI-panel layout, or the open/close
  path. It records what was tried and why it was reverted.
- **Lua 5.1 allows 200 locals per chunk.** `Core/SendTab.lua` has already failed
  to load once by passing it, and `Core/CollectTab.lua` is close too. New
  sections go on a table or in a `do` block; `.dev/tools/luacheck.js` reports
  the peak.
