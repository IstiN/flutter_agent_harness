#!/usr/bin/env bash
# Copyright (c) 2026, the Flutter Agent Harness authors.
# Use of this source code is governed by a MIT license that can be found
# in the LICENSE file.
#
# flake_watch_selftest.sh — fixture self-test for the flake watcher's
# issue dedup (flake_watch.py find_issue/ensure_issue, gh-1364).
#
# Between 2026-10-06 and 2026-10-07 the hourly watcher filed SEVEN
# duplicate `flake` issues for one file+test: find_issue searched
# `in:title` with an UNQUOTED `(#<digits>...` title fragment — GitHub
# search silently returns [] for that, so every run minted a fresh
# tracker. Proves, against a stubbed `gh` (no network, no token):
#   AC1 a tracker whose title carries the `(#<digits>...` suffix is still
#       FOUND — the stub emulates the search quirk, so any implementation
#       that still goes through `--search` no-ops and re-mints;
#   AC2 the watcher's issue listing never uses `--search` at all (also
#       drops the search-indexing-lag failure mode);
#   AC3 dedup keys on the body's `**File**:` path, not the truncated
#       title — two tests sharing their first 77 chars each resolve to
#       their own tracker;
#   AC4 a create that lands next to an existing open tracker for the
#       same file fails LOUDLY (guard rail) instead of minting silently;
#   AC5 a CLOSED tracker for the same file is re-opened + refreshed
#       instead of re-filed next to (the #1365-vs-proof-closed-#1362
#       class — the watcher's window keeps holding pre-fix red runs);
#   AC6 runs already appended via comments are not re-commented on the
#       next pass (run mentions count across body AND comments);
#   AC7 the plain create path still works on a clean slate.
# Same discipline as check_lockfiles_selftest.sh (#1100 pattern): the
# dedup's own red paths are fixture-tested so it cannot rot silently.
# Wired into ci.yml Static gates.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Stub `gh`: serves a JSON fixture of flake issues (open/closed), records
# every invocation to a log, and emulates the GitHub-search quirk that
# started gh-1364 (an unquoted `(#<digits>` in:title fragment matches
# nothing). State mutations (create/comment/reopen) write back to the
# fixture, so consecutive ensure_issue passes see each other's effects.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'PYEOF'
#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
state_path = os.environ["FAKE_GH_STATE"]
log_path = os.environ["FAKE_GH_LOG"]

with open(log_path, "a", encoding="utf-8") as f:
    f.write(json.dumps(args) + "\n")


def load():
    with open(state_path, encoding="utf-8") as f:
        return json.load(f)


def save(st):
    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(st, f, indent=2)


def flag(name):
    return args[args.index(name) + 1] if name in args else None


def emit(issues):
    print(json.dumps([{k: i[k] for k in
                       ("number", "title", "url", "body")}
                      for i in issues]))


def find(st, num):
    for state in ("open", "closed"):
        for i in st[state]:
            if i["number"] == num:
                return i
    raise SystemExit(f"stub gh: no issue #{num}")


if "issue" in args and "list" in args:
    st = load()
    if "--search" in args:
        # GitHub quirk (gh-1364): a fragment holding an unquoted `(#` or
        # `#` matches NOTHING, silently. A plain phrase substring-matches
        # titles (so the old code's luck on punctuation-free titles is
        # reproduced too).
        phrase = (flag("--search") or "").replace("in:title", "").strip()
        phrase = phrase.strip('"')
        if not phrase or "(" in phrase or "#" in phrase:
            emit([])
        else:
            emit([i for i in st[flag("--state") or "open"]
                  if phrase in i["title"]])
    else:
        emit(st[flag("--state") or "open"])
elif "issue" in args and "view" in args:
    i = find(load(), int(flag("view")))
    print(json.dumps({"body": i["body"], "comments": i.get("comments", [])}))
elif "issue" in args and "comment" in args:
    st = load()
    i = find(st, int(flag("comment")))
    i.setdefault("comments", []).append({"body": flag("--body")})
    save(st)
elif "issue" in args and "create" in args:
    st = load()
    num = st["next"]
    st["next"] += 1
    st["open"].append({"number": num, "title": flag("--title"),
                       "url": f"https://github.com/o/r/issues/{num}",
                       "body": flag("--body"), "comments": []})
    save(st)
    print(f"https://github.com/o/r/issues/{num}")
elif "issue" in args and "reopen" in args:
    st = load()
    i = find(st, int(flag("reopen")))
    st["closed"] = [x for x in st["closed"] if x["number"] != i["number"]]
    st["open"].append(i)
    save(st)
elif "issue" in args and "close" in args:
    st = load()
    i = find(st, int(flag("close")))
    st["open"] = [x for x in st["open"] if x["number"] != i["number"]]
    st["closed"].append(i)
    save(st)
else:
    raise SystemExit(f"stub gh: unexpected call: {args}")
PYEOF
chmod +x "$TMP/bin/gh"

export FAKE_GH_STATE="$TMP/state.json"
export FAKE_GH_LOG="$TMP/calls.log"

PATH="$TMP/bin:$PATH" python3 - "$HERE" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, sys.argv[1])
import flake_watch as fw  # noqa: E402

fails = 0


def check(desc, cond):
    global fails
    print(("  ok: " if cond else "  FAIL: ") + desc)
    if not cond:
        fails += 1


def reset(open_issues=(), closed_issues=()):
    with open(os.environ["FAKE_GH_STATE"], "w", encoding="utf-8") as f:
        json.dump({"open": list(open_issues),
                   "closed": list(closed_issues), "next": 900}, f)
    open(os.environ["FAKE_GH_LOG"], "w").close()


def calls():
    with open(os.environ["FAKE_GH_LOG"], encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


def state():
    with open(os.environ["FAKE_GH_STATE"], encoding="utf-8") as f:
        return json.load(f)


REPO = "o/r"
FILE = "test/integration/shell_job_countdown_pty_test.dart"
TEST = ("ten background bash jobs start, count down on camera, "
        "drain to 0 running (#573 review)")
TITLE_KEY = TEST if len(TEST) <= 80 else TEST[:77] + "..."


def tracker(num, file=FILE, title=None, body_runs=(), comments=()):
    title = title if title is not None else f"Flake: {TITLE_KEY}"
    body = (f"## Flake: `{TEST}`\n\n**File**: `{file}`\n\n"
            "Red in 2 distinct-SHA runs\n\n### Failing runs\n" +
            "".join(f"- https://github.com/{REPO}/actions/runs/{r}\n"
                    for r in body_runs))
    return {"number": num, "title": title,
            "url": f"https://github.com/{REPO}/issues/{num}",
            "body": body,
            "comments": [{"body": c} for c in comments]}


# AC1 — the headline bug: a title carrying `(#<digits>...` must still
# dedup. The stub emulates GitHub's silent-[] search quirk, so the old
# search-based find_issue returns None here and re-mints.
reset(open_issues=[tracker(1362)])
found = fw.find_issue(REPO, FILE)
check("AC1 tracker with a `(#573 review)` title suffix is found",
      found is not None and found["number"] == 1362)

# AC2 — the listing never goes through `--search` (search-index lag and
# the `(#` quirk both live there).
check("AC2 issue listing uses no --search",
      all("--search" not in c for c in calls()))

# AC3 — dedup keys on the **File**: body line, not the truncated title:
# two tests sharing their first 77 chars each resolve to their own
# tracker.
shared = "Flake: " + ("shared eighty character prefix " * 2)[:77] + "..."
reset(open_issues=[tracker(100, file="test/a_test.dart", title=shared),
                   tracker(101, file="test/b_test.dart", title=shared)])
check("AC3 file-keyed dedup picks the right tracker among "
      "identical titles",
      fw.find_issue(REPO, "test/b_test.dart")["number"] == 101)
url = fw.ensure_issue(REPO, "test/b_test.dart", "shared eighty character "
                      "prefix test b", [7], ["s" * 40])
check("AC3 ensure_issue appends to the b tracker, not the a twin",
      url.endswith("/issues/101")
      and len(state()["open"][0]["comments"]) == 0
      and len(state()["open"][1]["comments"]) == 1)

# AC4 — guard rail: a create landing next to an existing open tracker
# for the same file must fail LOUDLY, not mint a silent duplicate.
reset(open_issues=[tracker(1362)])
real_find_issue = fw.find_issue
fw.find_issue = lambda repo, file: None  # simulate a dedup miss
try:
    fw.ensure_issue(REPO, FILE, TEST, [1], ["a" * 40])
    raised = False
except Exception:
    raised = True
finally:
    fw.find_issue = real_find_issue
check("AC4 create beside an existing open tracker raises loudly", raised)
check("AC4 the fresh duplicate is closed, the original survives",
      len(state()["open"]) == 1 and state()["open"][0]["number"] == 1362
      and [i["number"] for i in state()["closed"]] == [900])

# AC5 — a CLOSED tracker for the same file is re-opened and refreshed
# instead of re-filed next to (the #1365-next-to-proof-closed-#1362
# class).
reset(closed_issues=[tracker(1362, body_runs=[37561842069])])
url = fw.ensure_issue(REPO, FILE, TEST, [37561842069, 37599999999],
                      ["a" * 40, "b" * 40])
st = state()
check("AC5 closed tracker is re-opened, not re-minted",
      url.endswith("/issues/1362")
      and any("reopen" in c for c in calls())
      and not any("create" in c for c in calls())
      and len(st["open"]) == 1 and st["open"][0]["number"] == 1362
      and not st["closed"])

# AC6 — runs appended via comments are not re-commented on the next
# pass: run mentions count across body AND comments.
reset(open_issues=[tracker(
    1362, body_runs=[1],
    comments=[f"Additional red runs: "
              f"https://github.com/{REPO}/actions/runs/2"])])
fw.ensure_issue(REPO, FILE, TEST, [1, 2, 3], ["a" * 40, "b" * 40,
                                              "c" * 40])
comment_bodies = "".join(c["body"] for c in state()["open"][0]["comments"])
check("AC6 run 2 (already in a comment) is not re-commented",
      comment_bodies.count("/runs/2") == 1)
check("AC6 run 3 (missing everywhere) is appended exactly once",
      comment_bodies.count("/runs/3") == 1)

# AC7 — the plain create path on a clean slate still works and passes
# the sole-tracker guard.
reset()
url = fw.ensure_issue(REPO, FILE, TEST, [9], ["d" * 40])
check("AC7 clean-slate create returns the minted tracker",
      url.endswith("/issues/900") and len(state()["open"]) == 1)
check("AC7 created body carries the **File**: dedup key",
      f"**File**: `{FILE}`" in state()["open"][0]["body"])
check("AC7 issue_tracks_file tolerates a bodyless issue payload",
      not fw.issue_tracks_file({"body": None}, FILE))

print("FAILURES: %d" % fails)
sys.exit(1 if fails else 0)
PYEOF
exit $?
