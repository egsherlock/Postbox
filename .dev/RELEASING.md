# Releasing Postbox

## Before the tag

Any change to functionality, defaults, styling or wording updates the documentation
in the same commit as the code. A release that ships behaviour nobody wrote down is
the thing this checklist exists to prevent.

- [ ] **`CHANGELOG.md`** — a new version heading and an entry per user-visible
      change. Never skipped: this is what CurseForge, Wago and WowUp show a player
      who is deciding whether to update. The newest heading must be the version
      being tagged, or the release stops before it builds. Voice rules below.
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

**Shape (Elliott, 2026-09-21: the long flat lists were "quite overwhelming").**
Every version is three sub-headings in this order, each omitted when empty. The
whole history was rewritten into it on 2026-09-27, so every version reads alike:

```
## 1.39.0

### New          things that did not exist before
### Improved     existing things that behave or look better
### Fixed        bugs: what went wrong, what happens now
```

A release players should notice -- a big one, or one that needs a full restart --
may open with one or two plain sentences above the headings: what it is, and
anything the player has to do. Nothing else goes above them.

**Concise, not necessarily one line (Elliott, 2026-09-27).** An entry explains
itself in a short, clear form, and is never a wall of text. Most are one line; a
larger feature that genuinely needs explaining may take a touch more (a second
line), but always concise. Lead with the bold effect in New and Improved; a Fixed
entry is a plain sentence. A run of small changes can share one un-bolded "Also:"
bullet at the end of Improved. Twenty bullets is too many: if a release has that
many, group them. Name things the way the addon names them. `## 1.40.1` is the
model.

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

## What a release shows

The repo holds one changelog, `CHANGELOG.md`, every version. It ships inside the
addon zip on purpose, for players who look there.

What CurseForge, Wago and the GitHub release show is shorter: **the newest five
versions, then a link to the full changelog on GitHub** (Elliott, 2026-09-27: the
whole file was far too long, one version alone too short). Nobody writes it by hand.
The release workflow runs `.github/release-changelog.py` on the tag, which writes
`.github/release-changelog.md` from `CHANGELOG.md`; `.pkgmeta` names that file as
the manual changelog. The packager reads it from the checkout and never copies it
into the zip. The GitHub release body is the same generated text, not the version's
own section.

- **The tag must match the newest heading.** `v1.40.2` needs `## 1.40.2` on top; a
  pre-release tag needs the version it will ship as (`v1.41.0-alpha.1` → `## 1.41.0`).
  Otherwise the workflow stops before anything is built or uploaded: write the
  section, delete the tag (`git tag -d vX.Y.Z && git push origin :vX.Y.Z`), and tag
  again.
- **Preview it** before tagging: `python3 .github/release-changelog.py vX.Y.Z`
  prints exactly what will be uploaded.
- **Correcting it after the tag.** Fix `CHANGELOG.md`, then
  `python3 .github/release-changelog.py vX.Y.Z > notes.md` and
  `gh release edit vX.Y.Z --notes-file notes.md` for GitHub; CurseForge's copy is
  edited on its site.

## Cutting the release

A release is `main` fast-forwarded to `beta` and the version tagged on `main`;
then `beta` is merged into `alpha` so the feature line carries everything that
shipped:

```
git checkout main
git merge --ff-only beta
git tag vX.Y.Z
git push origin main vX.Y.Z
git checkout alpha
git merge beta
git push origin alpha
```

`--ff-only` because `main` never holds anything `beta` lacks. If it refuses,
something was committed to `main` directly; sort that out before tagging.

The workflow writes the uploaded changelog, builds the zip, attaches it to the
GitHub release, and uploads to CurseForge. Nothing else is needed.

**Versioning.** Patch for fixes, minor for anything a user would call a feature,
and say so in the changelog either way.

**A release that adds NEW FILES needs a full client restart; one that only changes
existing files needs `/reload`.** Worth saying in the release notes when it applies
— v1.32.0 looked broken until a reload.

## Three branches, three channels

The branches match CurseForge's channels (CLAUDE.md, Workflow):

| Branch  | Holds                                                       | Tags              | Channel |
|---------|-------------------------------------------------------------|-------------------|---------|
| `main`  | what players have                                           | `v1.40.2`         | Release |
| `beta`  | the next release, tested by players: fixes, and features the maintainer has tested locally | `v1.41.0-beta.1` | Beta |
| `alpha` | new features being built, tested by the maintainer's dev builds | `v1.41.0-alpha.1` | Alpha |

**Fixes** are made on `beta`, tagged `-beta.N` if someone needs to test them, and
shipped as in *Cutting the release*. **Features** are built on `alpha` and move to
`beta` only once they are fleshed out and the maintainer has tested them locally;
beta is where adventurous players try them before everyone does, and a bigger or
more ambitious feature gets at least one beta round before `main`. Whenever `beta`
moves, it is merged into `alpha`, so the feature line always carries every fix.
Nothing is committed to `main` directly. A live fix that cannot wait for the
features on `beta` goes out from a short branch off `main` (1.40.2 did), after
which that branch is merged into `beta`.

Tagging a pre-release, from its own branch:

```
git checkout beta
git tag v1.40.2-beta.1 && git push origin v1.40.2-beta.1
```

The packager decides the channel from the tag's text: `beta` makes a CurseForge Beta
file and a GitHub pre-release, `alpha` the same one step quieter, and anything else
(`-rc` included) is a full release that everyone is offered. Nothing compares version
numbers: managers offer the newest file the player's channel allows, by date.

- **Who sees it.** Only players who opted in, and an Alpha player sees Betas and
  Releases too. WowUp's CurseForge build and Wago: right-click the addon → Channel.
  The CurseForge app: the addon's release-type setting. WowUp installing from
  GitHub has no per-addon channel; its installation-wide *Default Addon Channel*
  decides, for every GitHub addon in that install. Wago uploads are not wired yet
  (no `X-Wago-ID`, secret commented out in the workflow).
- **Numbering.** `-beta.1`, `-beta.2`, … (`-alpha.N` likewise), then the plain tag.
  Testers are moved onto the full release the moment it is published; tell a
  tester who switched channel for one fix to switch back.
- **Changelog.** Pre-releases add to the coming version's section, whose heading is
  the version it will ship as (`## 1.41.0`), not the pre-release number; the
  workflow refuses a tag without it. Each uploads what that section holds so far
  and the four versions before it, then the link, like any release.
- **One tester, one question.** Every GitHub release carries its zip; a link to the
  pre-release page is enough for someone who installs by hand.

## Where the publishing bits live

| | |
|---|---|
| CurseForge project id | `Postbox.toc` → `## X-Curse-Project-ID` |
| CurseForge API key | GitHub repo → Settings → Secrets → `CF_API_KEY` |
| Wago / WoWInterface | Add the id to the `.toc` and uncomment the secret in the workflow |
| What ships in the zip | `.pkgmeta` — verified against the built artifact, not assumed |
| The uploaded changelog | `.github/release-changelog.py`, run by `.github/workflows/release.yml` |

**CurseForge's own repository packaging must stay OFF.** The GitHub Action is the
only thing that builds and uploads; with CF also watching the repo, every tag would
produce two competing files.

Listing metadata that is set once — project name, category, licence, tags — is in
`curseforge-setup.md`. The description body is `curseforge-listing.md`, which is
that and nothing else: open, select all, paste.
