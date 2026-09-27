# Releasing Postbox

## Before the tag

Any change to functionality, defaults, styling or wording updates the documentation
in the same commit as the code. A release that ships behaviour nobody wrote down is
the thing this checklist exists to prevent.

- [ ] **`CHANGELOG.md`** — a new version heading and an entry per user-visible
      change. Never skipped: this is what CurseForge, Wago and WowUp show a player
      who is deciding whether to update. Voice rules below.
- [ ] **`README.md`** — if the feature set, defaults or screenshots moved.
- [ ] **`docs/curseforge-listing.md`** — same test. This is the CurseForge and Wago
      description, and it reaches far more people than the README does. A feature
      documented only on GitHub is invisible to most of the people using the addon.
- [ ] **`Postbox.toc`** `## Notes` — only if the one-line pitch changed. It is kept
      identical to the CurseForge summary on purpose.
- [ ] **Locales** — every new user-facing string in all seven blocks.
- [ ] **Checkers** — all five in `.dev/tools/` clean. A bare run checks the whole
      addon.

## The changelog is written for players

It is the most-read thing in the repository, and the only documentation most users
will ever see. Plain English, describing what a person notices.

**Shape, from 1.36 on (Elliott, 2026-09-21: the long flat lists were "quite
overwhelming").** Every version is three sub-headings in this order, each omitted
when empty:

```
## 1.39.0

### New          things that did not exist before
### Improved     existing things that behave or look better
### Fixed        bugs, one line each: what went wrong, what happens now
```

A release players should notice -- a big one, or one that needs a full restart --
may open with one or two plain sentences above the headings: what it is, and
anything the player has to do. Nothing else goes above them.

One item is one bullet of one to three lines. Lead with the bold effect. A run of
small cosmetic changes can share one un-bolded bullet at the end of Improved. Twenty
bullets is too many: if a release has that many, group them. The GitHub release
notes are the version's section verbatim (`gh release edit vX.Y.Z --notes-file`
if they need correcting after the tag; CurseForge's copy is edited on its site).

**Lead with the effect, not the cause.** Someone scanning the list wants to know
whether this release fixes the thing that annoyed them.

> Yes — *"Fixed: the window could not be dragged by the right-hand end of its title
> bar. Every window style was affected; all are fixed."*
>
> No — *"Fixed hit-test propagation on the status overlay frame."*

No file names, no function names, no Lua, no "refactored", no internals. The *why*
is welcome where it helps somebody trust a fix, or where the cause is genuinely
interesting — the mechanism is not. Commit messages are where the mechanism goes;
they have a different audience and can be as technical as they need to be.

An internal change with no user-visible effect still gets an entry, and it says so:
*"Nothing you can see changed."* That is more honest than silence and stops people
wondering what they missed.

## Cutting the release

```
git tag vX.Y.Z && git push origin vX.Y.Z
```

The workflow builds the zip, attaches it to the GitHub release, and uploads to
CurseForge. Nothing else is needed.

**Versioning.** Patch for fixes, minor for anything a user would call a feature,
and say so in the changelog either way.

**A release that adds NEW FILES needs a full client restart; one that only changes
existing files needs `/reload`.** Worth saying in the release notes when it applies
— v1.32.0 looked broken until a reload.

## Betas

A beta is a tag with `beta` in its name, cut from `main` like any other. No branch,
nothing to switch on at CurseForge or GitHub:

```
git tag v1.41.0-beta.1 && git push origin v1.41.0-beta.1
```

The packager decides the channel from the tag's text: `beta` makes a CurseForge Beta
file and a GitHub pre-release, `alpha` the same one step quieter, and anything else
(`-rc` included) is a full release that everyone is offered. Nothing compares version
numbers: managers offer the newest file the player's channel allows, by date.

- **Who sees it.** Only players who opted in. WowUp's CurseForge build and Wago:
  right-click the addon → Channel → Beta. WowUp installing from GitHub has no
  per-addon channel; its installation-wide *Default Addon Channel* decides, for
  every GitHub addon in that install.
- **Numbering.** `-beta.1`, `-beta.2`, … then the plain tag. Testers are moved onto
  the full release the moment it is published.
- **Changelog.** The whole file is uploaded with every file, beta or not. Betas add
  to the coming version's section; the heading carries the version it will ship as
  (`## 1.41.0`), not the beta number.
- **A stable fix while `main` carries a beta.** Branch from the last full tag, fix,
  tag the patch (`v1.40.1`) there, merge it back to `main`. A full release
  published after a beta is newer by date, so testers drop onto it until the next
  beta tag.
- **One tester, one question.** Every GitHub release carries its zip; a link to the
  pre-release page is enough for someone who installs by hand.

## Where the publishing bits live

| | |
|---|---|
| CurseForge project id | `Postbox.toc` → `## X-Curse-Project-ID` |
| CurseForge API key | GitHub repo → Settings → Secrets → `CF_API_KEY` |
| Wago / WoWInterface | Add the id to the `.toc` and uncomment the secret in the workflow |
| What ships in the zip | `.pkgmeta` — verified against the built artifact, not assumed |

**CurseForge's own repository packaging must stay OFF.** The GitHub Action is the
only thing that builds and uploads; with CF also watching the repo, every tag would
produce two competing files.

Listing metadata that is set once — project name, category, licence, tags — is in
`curseforge-setup.md`. The description body is `curseforge-listing.md`, which is
that and nothing else: open, select all, paste.
