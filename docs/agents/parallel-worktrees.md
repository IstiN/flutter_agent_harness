# Working in parallel: shared checkout + worktrees

> Moved verbatim from `AGENTS.md` (gh-2181 — the slim-AGENTS.md card). Canonical reference; the slim AGENTS.md carries the one-line summary and points here.

## Working in parallel: shared checkout + worktrees

The user's primary working directory is this checkout — they may be
running an LLM loop here at the same time as any agent. To avoid
contention and stale-context confusion, agents follow this policy:

- **Do not modify files in this shared checkout unless the user asked for
  it.** For review, `gh api` + `git fetch` + `git show` /
  `git diff origin/<branch>..HEAD` is enough — no local checkout needed.
- **Do not run heavy commands in the shared checkout** (`dart test` for
  the whole suite, full `dart analyze`). They compete with the user's
  own LLM loop for CPU/IO and can flip its context mid-task.
- **Do not `git stash` the user's WIP.** Their uncommitted changes are
  sacred; never pop, drop, or apply them. If a checkout conflict blocks
  you, ask the user before touching `git stash`.
- **If a worktree is genuinely required** (running `dart test`/`analyze`
  locally against a non-current branch, exploring a fresh PR head):
  - **Ask the user first** whether to proceed — by default, review
    should not need a worktree at all.
  - If the user agrees, create under `flutter_agent/.worktrees/<name>/`
    (the in-repo location they picked — dot-prefix keeps it visually
    separate in `ls`, and `rm -rf .worktrees/` cleans everything in one
    shot). Never in the parent directory `../<name>/`, which has been
    the source of orphan pollution before.
  - Use `git worktree add --detach .worktrees/<name> origin/<branch>`
    against the remote tracking ref — never the local branch ref, which
    the user may have moved on.
  - **`git worktree remove` the moment you're done.** Don't leave stale
    worktrees behind.
  - The `.worktrees/` directory should be in `.gitignore` (so worktrees
    never get committed by accident). Add it there **only after
    confirming with the user** — silent `.gitignore` edits conflict
    with parallel agents who may already have it dirty.
- **Communicate with peer agents through the inbox fabric**, not by
  reading or writing their working files. `agent_directory` lists
  siblings; `agent_message` to the relevant mailbox id. Their
  `memory/note/` files are theirs — leave them alone.

