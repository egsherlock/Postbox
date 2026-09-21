# Working on Postbox

## Workflow

- **Commit straight to `main`.** No feature branches, no pull requests for our
  own work. PRs are for outside contributors who cannot push here.
- **Offer a local test before any tag.** Nothing ships without the option of
  swapping the changed files into the live WoW install and `/reload`-ing first.
  Note the constraint: a *cloud* session cannot reach that folder — it can only
  hand over the files. A Claude Code session running on the maintainer's own
  machine can copy them into
  `World of Warcraft\_retail_\Interface\AddOns\Postbox\` directly.
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
- **Locales are complete, not partial** — six blocks in `Core/Locales.lua`, and
  a new user-facing string is added to all of them.
- **Postbox never touches Blizzard's mail code.** Read `COMBAT_TAINT.md` before
  changing anything near `MailFrame`, the UI-panel layout, or the open/close
  path. It records what was tried and why it was reverted.
- **`Core/SendTab.lua` is near Lua 5.1's 200-local ceiling** and has already
  failed to load once because of it. Prefer moving code out to adding locals.
