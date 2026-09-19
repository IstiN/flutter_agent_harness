**Dropped again — wider set this time.** Removed from the branch in this round's final state:

- `input/gh-671/pr_diff.txt`, `pr_info.md`, `pr_discussions.md`, `pr_discussions_raw.json`, `merge_conflicts.md`
- the review job's outputs: `outputs/pr_review.json`, `outputs/pr_review_comments/`, `outputs/pr_review_general.md`, `outputs/pr_base_branch.txt`, `outputs/rca.md`
- the superseded round-1 replies (`outputs/review_replies/` round-1 set)

The re-commit mechanism is confirmed exactly as this thread says: the factory re-provisions the job inputs into the workspace, and the auto-save's `git add -A` commits whatever is there — so removal in one round is undone by the next round's workspace. The durable fix (auto-save scoped to intended paths, or `input/`+`outputs/` excluded on job branches) is factory-pipeline configuration; it does not exist in this repository's source (`grep -rn "WIP auto-save" lib/ bin/` is empty), so it cannot land in this PR. Note this round's own deliverables (`outputs/response.md`, `outputs/review_replies*`) must exist transiently for the factory to post them — the path filter is what keeps them off the branch long-term.
