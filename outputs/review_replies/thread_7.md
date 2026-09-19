# Re: 🟡 IMPORTANT: the PR commits the CI runner's own input artifacts — including its own diff

Removed from the PR: `input/gh-671/pr_diff.txt` and `input/gh-671/pr_info.md` are `git rm`'d (staged deletions), so the self-referential diff and job-info artifacts no longer ship with the branch.

The broader fix belongs to the factory, not this repo — the dev job's auto-save should `git add` only intended paths (or job branches should gitignore `input/`). Noted as an automation issue; it can't be fixed from inside this PR without breaking the job's own inputs. The remaining tracked files under `input/gh-671/` (`ticket.json`, `ticket.md`, `pr_discussions*`) were resolved/kept because the blocking-conflict review asked for the ticket files to be fixed rather than dropped.
