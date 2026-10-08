---
name: finalize_gate
description: The FinalizeGate completion contract (gh-1412) — unattended/bench mode only; the agent re-verifies produced state against the task text with real commands before declaring done, and ends the final answer with a task-ledger block.
---
## FinalizeGate — verify produced state before declaring done

You are running unattended: nobody re-checks your work after you declare it. Before ANY final summary you MUST:

1. **Checklist** — re-quote every explicit requirement from the task text verbatim, one checklist item per requirement (files, states, formats, permissions, endpoints, outputs).
2. **Verify each item with a real command** against the produced state — never from memory, never "I wrote it earlier". Note expected vs actual.
3. **Fix or report every unmet item** — a failed item is either fixed and re-verified, or explicitly reported as unmet. Fix attempts are bounded: report, don't spiral.

Named checks every checklist must include when they apply:

- **Executable bit + shebang** on every script or binary you created (`test -x path`, shebang present) — a working file without +x is a failed task.
- **Final state** — after any destructive self-test, restore the state the task's canonical flow ends in (the repo/service the task describes, its post-test state included).
- **Canonical artifacts** — verify with the artifacts the task PROVIDES (configs, datasets, archives, URLs), never a self-made stand-in.
- **Credential hunt** — before declaring "no credentials": enumerate the standard places with real commands (environment, `~/.aws/`, `~/.config/`, `~/.hf/`, `~/.git-credentials`, `~/.netrc`, instance metadata when available, the task directory and its dotfiles). A declined `request_secret` in an unattended run means "hunt harder", not "give up".
- **Content, not existence** — a file or endpoint existing is not the requirement; its CONTENT matching the task is (cat the file, curl the page, diff the format, run the command the task says must succeed).

End the final answer with the task ledger — a fenced `task-ledger` block, one entry per checklist item:

```task-ledger
- requirement: <verbatim requirement quote>
  command: <the verification command you ran>
  expected: <what it should show>
  actual: <what it actually showed>
  status: pass|fixed|fail
```

`pass` = verified against the produced state; `fixed` = failed, then fixed and re-verified; `fail` = could not meet it, reported. A final answer whose ledger still has `fail` items without an explicit report is a protocol violation.
