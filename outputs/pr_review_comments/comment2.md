🟡 **IMPORTANT (reduced but still present): job artifacts remain committed**

Progress this round: `pr_diff.txt` and `pr_info.md` are gone and the
conflict markers are resolved. Still on the branch, though: this file
(+1060 lines of review-thread dump), `pr_discussions_raw.json`,
`merge_conflicts.md`, and the previous review round's outputs
(`outputs/pr_review*`, `outputs/review_replies/`). These are factory job
inputs/outputs, not gh-671 deliverables — they bloat the diff and, per the
established ping-pong, will be refreshed by every future job's auto-save.

Same exit as before: the durable fix is the factory auto-save path filter;
for this PR, drop them in the final pre-merge push.
