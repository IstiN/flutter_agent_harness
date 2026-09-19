🚨 **BLOCKING: unresolved git merge-conflict markers committed to the branch**

This file is committed at HEAD with TWO nested, unresolved stash-conflict
blocks (`<<<<<<< Updated upstream` / `=======` / `>>>>>>> Stashed changes`,
lines 5–13) and is **no longer valid JSON** (`json.loads` fails: "Expecting
property name enclosed in double quotes: line 5"). The same markers are
committed in `input/gh-671/ticket.md` (lines 8–19) and `input/ticket.md`
(lines 3+).

Beyond being broken content in the repo, an invalid `ticket.json` will fail
the next factory job that parses it.

Fix: resolve the conflicts (keep the version with the `## Machine jobs`
section) and re-commit — or drop these runner artifacts from the PR entirely
(see the related comment on `input/gh-671/pr_diff.txt`).
