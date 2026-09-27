"""Write the changelog a release uploads.

CurseForge, Wago and the GitHub release all show this text: the newest five
versions in CHANGELOG.md, then a link to the whole file on GitHub. The repo
keeps one changelog; this excerpt is made from it at build time and never
ships in the zip (see .pkgmeta). The zip still carries the full CHANGELOG.md.

    python3 .github/release-changelog.py v1.41.0-beta.1 > .github/release-changelog.md

The newest heading must be the version being tagged: v1.40.2 needs
"## 1.40.2" on top, and a beta (v1.41.0-beta.1) needs the version it will ship
as, "## 1.41.0". A tag with no section of its own stops the release here,
before anything is built or uploaded.
"""

import sys

KEEP = 5
FULL_CHANGELOG = "https://github.com/egsherlock/Postbox/blob/main/CHANGELOG.md"


def fail(message):
    # "::error::" is how a GitHub Actions log marks the line that failed the run.
    sys.stderr.write("::error::" + message + "\n")
    sys.exit(1)


def main(argv):
    if len(argv) not in (2, 3):
        fail("usage: release-changelog.py TAG [CHANGELOG.md]")
    tag = argv[1]
    path = argv[2] if len(argv) == 3 else "CHANGELOG.md"

    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()

    starts = [i for i, line in enumerate(lines) if line.startswith("## ")]
    if not starts:
        fail(path + " has no version headings")

    version = tag[1:] if tag.startswith("v") else tag
    version = version.split("-")[0]  # 1.41.0-beta.1 ships as 1.41.0
    top = lines[starts[0]][3:].split()
    if not top or top[0] != version:
        fail("%s is tagged, but the newest section in %s is \"%s\". "
             "Write its changelog as \"## %s\" before tagging."
             % (tag, path, lines[starts[0]], version))

    end = starts[KEEP] if len(starts) > KEEP else len(lines)
    body = lines[starts[0]:end]
    while body and not body[-1].strip():
        body.pop()
    body += [
        "",
        "---",
        "",
        "Every earlier version is in the [full changelog on GitHub](%s)."
        % FULL_CHANGELOG,
    ]

    # Bytes, not text: the same UTF-8 and the same line endings on any machine.
    sys.stdout.buffer.write(("\n".join(body) + "\n").encode("utf-8"))


if __name__ == "__main__":
    main(sys.argv)
