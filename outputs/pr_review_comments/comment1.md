🚨 **BLOCKING (regressed): conflict markers are back at HEAD — the auto-save re-committed them after they were resolved**

The rework job resolved these markers (verified: the file was valid JSON at
`5842d86d`), but auto-save commit `9911dc07` (09:49) re-committed the broken
content. At the current HEAD:

- `input/gh-671/ticket.json` — `<<<<<<< Updated upstream` at line 5;
  **invalid JSON again** (`json.loads` fails at line 5).
- `input/gh-671/ticket.md` — marker at line 13.
- `input/ticket.md` — marker at line 3.

Root cause: the job workspaces still carry the unresolved merge (the review
workspace has `UU input/ticket.md` / `AA ticket.json|ticket.md` right now),
and every "WIP auto-save" `git add -A`s that conflicted working tree,
re-committing the markers. Fixing the files in one job is not enough — the
next auto-save re-breaks them.

Fix (both halves, or this ping-pongs forever):
1. Resolve the conflict in the source workspace and commit the resolution.
2. Change the factory auto-save to skip conflicted paths (e.g. refuse to
   `git add` files matching `^<<<<<<< ` / unmerged `git ls-files -u` entries)
   so a conflicted checkout can never be committed.
