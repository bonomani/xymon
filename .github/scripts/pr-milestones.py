#!/usr/bin/env python3
"""Keep the milestone of every merged pull request equal to the open release.

A pull request merged into main ships with the next release, and the tree
already says which one that is: the open section at the top of RELEASENOTES,
"Changes for X.Y.Z (not yet released)", which RELEASING.md has the first pull
request after a release open. That heading is the only source read, so the
milestone follows the release manager and nothing here names a version.

A merged pull request on another milestone, or on none, is put on that one.
A pull request merged into any branch but main is not touched: Changes and
release/* are the release manager's. A milestone that does not exist on
GitHub is reported, not created -- creating it is the release manager's
decision too.

Usage:  pr-milestones.py [--apply] [--pr N]   (default is a dry run)
        pr-milestones.py --self-test          (offline, no GitHub access)

RELEASENOTES is read from the current directory, or from $RELEASENOTES.
"""

import json
import os
import re
import subprocess
import sys

REPO = os.environ.get("REPO", "xymon-monitoring/xymon")
RELEASENOTES = os.environ.get("RELEASENOTES", "RELEASENOTES")
BASE = "main"

# The heading RELEASING.md describes, and nothing looser: a version is three
# numbers, and only the open section carries "(not yet released)".
OPEN_SECTION = re.compile(r"^Changes for (\d+\.\d+\.\d+) \(not yet released\)[ \t]*$", re.M)


def gh(*args):
    out = subprocess.run(["gh", *args], capture_output=True, text=True, check=True)
    return out.stdout


def next_release(text):
    """The version of the open RELEASENOTES section, or None when none is open."""
    found = OPEN_SECTION.findall(text)
    if len(found) != 1:
        return None
    return found[0]


def merged_prs(number=None):
    """Pull requests merged into main: number, title, milestone title or None."""
    if number is not None:
        try:
            raw = gh("pr", "view", str(number), "--repo", REPO,
                     "--json", "number,title,milestone,baseRefName,state")
        except subprocess.CalledProcessError as e:
            print("#%s: %s" % (number, e.stderr.strip() or "gh pr view failed"), file=sys.stderr)
            return None
        p = json.loads(raw)
        if p["state"] != "MERGED" or p["baseRefName"] != BASE:
            print("#%d is %s into %s, not merged into %s; nothing to set"
                  % (p["number"], p["state"].lower(), p["baseRefName"], BASE))
            return []
        prs = [p]
    else:
        raw = gh("pr", "list", "--repo", REPO, "--state", "merged", "--base", BASE,
                 "--limit", "1000", "--json", "number,title,milestone")
        prs = json.loads(raw)
    return [{"number": p["number"], "title": p["title"],
             "milestone": (p.get("milestone") or {}).get("title")} for p in prs]


def milestones():
    raw = gh("api", "repos/%s/milestones?state=all&per_page=100" % REPO)
    return {m["title"] for m in json.loads(raw)}


def plan(prs, version):
    """The pull requests whose milestone is not the open release, with what it is."""
    return [(p["number"], p["milestone"], p["title"]) for p in prs if p["milestone"] != version]


def self_test():
    """The heading rule and the plan on fixed input, without GitHub."""
    text = ("Xymon release notes\n\nChanges for 4.3.31 (not yet released)\n"
            "=====================================\n\nChanges for 4.3.30\n")
    assert next_release(text) == "4.3.31", next_release(text)
    # A released heading, a version with two numbers, a trailing word, a
    # fenced-looking mention: none is the open section.
    for bad in ("Changes for 4.3.30\n", "Changes for 4.3 (not yet released)\n",
                "Changes for 4.3.31 (not yet released) soon\n",
                "see Changes for 4.3.31 (not yet released)\n"):
        assert next_release(bad) is None, bad
    # Two open sections is an error in the file, not a choice to make here.
    assert next_release(text + "Changes for 4.3.32 (not yet released)\n") is None

    prs = [
        {"number": 1, "title": "a", "milestone": "4.3.31"},
        {"number": 2, "title": "b", "milestone": None},
        {"number": 3, "title": "c", "milestone": "4.3.32"},
    ]
    got = plan(prs, "4.3.31")
    want = [(2, None, "b"), (3, "4.3.32", "c")]
    assert got == want, "plan %r, expected %r" % (got, want)
    print("self-test: heading parsed, %d of %d pull requests to move as expected"
          % (len(want), len(prs)))
    return 0


def main():
    if "--self-test" in sys.argv:
        return self_test()
    apply_changes = "--apply" in sys.argv
    one = None
    if "--pr" in sys.argv:
        one = int(sys.argv[sys.argv.index("--pr") + 1])

    with open(RELEASENOTES, encoding="utf-8") as f:
        version = next_release(f.read())
    if version is None:
        print("%s has no single 'Changes for X.Y.Z (not yet released)' heading; "
              "nothing to compare against" % RELEASENOTES, file=sys.stderr)
        return 1

    prs = merged_prs(one)
    if prs is None:
        return 1
    moves = plan(prs, version)
    print("open release: %s   merged into %s: %d   off its milestone: %d"
          % (version, BASE, len(prs), len(moves)))
    if not moves:
        print("nothing to change")
        return 0

    if version not in milestones():
        print("milestone %s does not exist on %s; create it, then rerun"
              % (version, REPO), file=sys.stderr)
        for n, cur, title in moves:
            print("  #%-5s %-8s %s" % (n, cur or "-", title))
        return 1

    for n, cur, title in moves:
        print("  #%-5s %-8s -> %s   %s" % (n, cur or "-", version, title))
        if apply_changes:
            gh("pr", "edit", str(n), "--repo", REPO, "--milestone", version)

    if not apply_changes:
        print("dry run -- pass --apply to set them")
    return 0


if __name__ == "__main__":
    sys.exit(main())
