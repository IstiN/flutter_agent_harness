🚨 **BLOCKING (5th consecutive state — unchanged at HEAD `c84027ae`)**

Still committed at HEAD: `<<<<<<< Updated upstream` at line 5 of this file
(invalid JSON, parser-verified), line 15 of `input/gh-671/ticket.md`, and
line 3 of `input/ticket.md`. The only new commit since the last review is a
merge of `main` — no new resolution attempt has landed.

Transition history of this defect on the branch: broken → fixed → broken →
fixed → **broken (current)**. As established in the previous round, this
cannot converge through in-PR edits because every job workspace is
re-provisioned with the unmerged merge and the auto-save re-commits it.
The path out is unchanged:

1. Factory auto-save refuses conflicted state (`git ls-files -u` non-empty
   → do not stage/commit).
2. One final cleanup push (resolve + drop job artifacts) immediately before
   merge, with no further auto-save firing in between.
