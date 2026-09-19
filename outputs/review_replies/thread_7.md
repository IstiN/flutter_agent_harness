**Dropped again** — same ping-pong as the conflict markers: removed in the previous rework round, re-committed by the review workspace's auto-save (`git add -A` over a workspace where the factory had re-provisioned the job inputs), dropped again now.

Removed from the branch this round: `input/gh-671/pr_diff.txt`, `pr_info.md`, `pr_discussions.md`, `pr_discussions_raw.json`, `merge_conflicts.md`, plus the review job's own outputs (`outputs/pr_review.json`, `outputs/pr_review_comments/`, `outputs/pr_review_general.md`, `outputs/pr_base_branch.txt`, `outputs/rca.md`) and the superseded round-1 replies.

The durable fix is the auto-save path filter described in the round-2 threads — that is factory-pipeline configuration, outside this repository's source, so it cannot land in this PR.
