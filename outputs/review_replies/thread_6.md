# Re: 🚨 BLOCKING: unresolved git merge-conflict markers committed to the branch

Resolved. All three files were unmerged (`both added`/`both modified`) in the `main` merge and are now staged without markers:

- `input/gh-671/ticket.json` — kept the description with the full `## Machine jobs` section (dev + both review runs); `json.loads` now passes.
- `input/gh-671/ticket.md` — same resolution, all three job lines.
- `input/ticket.md` — same resolution.

`git diff --check` is clean and `grep -r '<<<<<<<'` finds no markers anywhere in `input/`.
