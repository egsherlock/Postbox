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

- **Three branches, matching CurseForge's three channels.**
  - `main` is what players have. It moves only when a version ships:
    fast-forwarded to `beta` and tagged (`v1.40.2`, Release channel). Nothing is
    committed to it directly.
  - `beta` is the next release, tested by real players: fixes, and features
    that are fleshed out and have passed the maintainer's own local testing.
    Beta tags (`v1.41.0-beta.1`) go to the Beta channel, so adventurous
    players can try them before they reach everyone.
  - `alpha` is where new features are built and iterated, tested by the
    maintainer through dev builds. Alpha tags (`v1.41.0-alpha.1`) go to the
    Alpha channel.
- **Fixes go on `beta`; features go on `alpha`.** A feature moves from `alpha`
  to `beta` only once it is fleshed out and the maintainer has tested it
  locally. Bigger or more ambitious features get at least one beta round with
  players before `main`. Whenever `beta` moves, it is merged into `alpha`, so
  the feature line always carries every fix. If a live fix is urgent while
  `beta` holds features still under test, raise it before choosing how to ship
  it (a short branch off `main`, as 1.40.2 was, is the usual answer).
- **Branches are pushed as work lands**, so GitHub mirrors what is being built.
  Tags publish to players and are cut only on the maintainer's word.
- **No other long-lived branches, no pull requests for our own work.** Short
  local branches merged and deleted are fine. PRs are for outside contributors
  who cannot push here.
- **Dev builds for the live install** come from the branch being worked on,
  stamped `-devN` on the version it will ship (`v1.41.0-devN` from `alpha`,
  `v1.40.2-devN` from `beta`).
- **Offer a local test before any tag.** Nothing ships without the option of
  swapping the changed files into the live WoW install and `/reload`-ing first.
  A session on the maintainer's own machine copies them into
  `World of Warcraft\_retail_\Interface\AddOns\Postbox\` directly; a cloud
  session cannot reach that folder and hands the files over instead.
- **A release is a tag, and only a tag.** Merging to `main` builds nothing and
  uploads nothing. `.github/workflows/release.yml` fires on `v*` only.

## Version numbers

Addon managers compare each part as a number, so the minor counts on past 9:
v1.39.0 is followed by v1.40.0, never v1.4.0, which would read as older and
never be offered as an update. The last tag is the current version.

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
