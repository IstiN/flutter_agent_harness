🟡 **IMPORTANT (unchanged at HEAD): self-referential runner artifacts still committed**

`input/gh-671/pr_diff.txt` (this PR's own truncated diff), `pr_info.md`, and
`pr_discussions*` remain on the branch. Dropped once by the rework job,
re-committed by the next auto-save — the factory re-provisions job inputs
into every workspace and the auto-save commits them. Until the auto-save
gains a path filter (`input/` + job `outputs/` excluded on job branches),
the practical exit for this PR is: drop these files in the final pre-merge
push and merge before the next auto-save fires.
