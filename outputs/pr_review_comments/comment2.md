🟡 **IMPORTANT (regressed): the self-referential runner artifacts are back**

The rework job removed `input/gh-671/pr_diff.txt` and `pr_info.md` from the
PR, but auto-save `9911dc07` re-committed both — this file is once again the
PR's own truncated diff inside the PR. The PR now also carries
`input/gh-671/pr_discussions.md`, `pr_discussions_raw.json`,
`merge_conflicts.md`, and the review job's outputs (`outputs/pr_review*`,
`outputs/review_replies/*`).

This confirms the leak is in the factory auto-save step, not in any one job:
it commits whatever the workspace contains, including job inputs and outputs.
Until the auto-save is scoped to intended paths (or `input/`+job outputs are
excluded), every review/rework round will re-add these. Please drop them from
the branch again before merge AND fix the auto-save path filter.
