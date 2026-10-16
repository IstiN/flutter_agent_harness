---
name: finalize_gate
description: The FinalizeGate completion contract (gh-1412) — unattended/bench mode only; the agent re-verifies produced state against the task text with real commands before declaring done, and ends the final answer with a task-ledger block.
---
## FinalizeGate — verify produced state before declaring done

You are running unattended: nobody re-checks your work after you declare it. **Trivial turns — answer directly:** when the turn made NO tool calls at all — no files written or edited, no commands run, nothing created or changed; a pure question answered from what you already know — there is nothing to verify. Skip the checklist AND the task ledger entirely and reply plainly; the gate exists for produced state, and with none the checklist is noise.

The contract does NOT apply to turns like:

- **"почему ты баш команды вызываешь?"** — a "why did you…" question. Just answer it directly: no checklist, no verification commands, no ledger.
- **"what does the `read` selector `:N` do?"** — a "what does X do" question. Just explain it: no verification commands, no ledger.
- **"what's the status?"** — a status/explanation answer about work already done. Report it plainly: no re-verification, no ledger.

Those turns produced no state; running the checklist ritual on them is noise. Otherwise, before ANY final summary you MUST:

1. **Checklist** — re-quote every explicit requirement from the task text verbatim, one checklist item per requirement (files, states, formats, permissions, endpoints, outputs).
2. **Verify each item with a real command** against the produced state — never from memory, never "I wrote it earlier". Note expected vs actual.
2.5. **Grader parity** — your shell is not the verifier's: if the task ships a runnable verifier, test, or entry point the grader will call, run THAT command the way the grader will — neutral cwd (`cd /` — a different working directory, never the session cwd), fresh subprocess, clean env (no session-exported vars) — and compare stdout, stderr, and exit code against the earlier in-session run. Any divergence — different output, files created via relative paths now missing, locale/encoding-dependent output — is a `fail` item to fix before finalizing. The ledger row for the main artifact uses this invocation as its `command:`.
3. **Fix every unmet item** — a failed item is fixed and re-verified. Fix attempts are bounded (don't spiral on one dead end — switch approach), but a bounded attempt is NEVER a permission to stop: while budget remains, the next compliant action is another approach, not a final answer.

**The unmet-item wall (gh-1646).** A final answer that still carries `fail` items is compliant ONLY when one of these holds:

- **The wall is reached** — the deadline is effectively spent: there is no time for another fix-verify cycle (compare `date +%s` with `FA_DEADLINE_EPOCH_MS/1000` when the run exports it; "I feel done" is not the wall).
- **Every unmet item is truly blocked** — by something you cannot change (a credential declined after the full hunt, an unavailable network), and each such item's `actual` NAMES the blocker.

Anything else — budget remaining, no named blocker — is not a stopping point: the ONLY compliant action is to continue working. An honest ledger is not an exit license. Ending with a "to finish from here" plan while minutes of budget remain is a protocol violation, not a graceful hand-off.

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

`pass` = verified against the produced state; `fixed` = failed, then fixed and re-verified; `fail` = could not meet it — a compliant terminal state ONLY at the wall or with the per-item named blocker in `actual`. A final answer whose ledger still has `fail` items without the wall reached or a named blocker per item is a protocol violation — with budget remaining, go back to work instead of reporting.
