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
2.6. **Conformance coverage** — applies ONLY when the final claim includes behavioral conformance: "matches the reference/specification", parity with an existing implementation, protocol/format compliance — any domain. Happy-path agreement certifies nothing about rejection paths or option combinations: two implementations agreeing on every well-formed input can still diverge exactly where one of them must say no. A conformance item counts as verified only when the checklist also quotes **negative and combination checks**, each one actually run and quoted in its ledger row: inputs that must be rejected or must error, combinations of incompatible/mutually exclusive options that must be refused, empty and corrupt inputs, boundary values, "must NOT work" / "must not find" cases — alongside the happy paths. A blanket "everything matches" without such coverage is not verified: mark the item `fail` and run the missing cases.
3. **Fix every unmet item** — a failed item is fixed and re-verified. Fix attempts are bounded: don't spiral on one dead end — switch approach.
4. **Final state is the deliverable** — never uninstall, stop, reset, or clean up what you produced while finalizing. Verification steps must be read-only or additive (a smoke probe, a curl, a diff) — never destructive. Cleanup happens only if the task explicitly requires it. ❌ Wrong: "verified, then reset to a clean state so the checker's commands run exactly as written" — the produced state no longer exists at grading, and that is a `fail`, not a clean handoff.

**Feasibility before commitment.** Before starting any step whose cost can dominate the remaining budget (from-source builds, large downloads, brute-force searches), estimate its duration and compare it against the time-left notices. If the estimate exceeds the budget, switch to a cheaper strategy that still satisfies the task (binary packages, targeted sub-builds, reduced scope the task allows) — or, when no satisfying strategy fits, the next-best partial — never gamble the whole window on a path you already know cannot finish.

**Work to the wall.** Your time-left notices report the remaining budget. While work remains, the next compliant action is another approach — not a final answer. Do not stop to wrap up: you are interrupted automatically when time expires, so no manual saving-up is needed. A final answer is written when the task is done or the deadline notice says so.

Named checks every checklist must include when they apply:

- **Executable bit + shebang** on every script or binary you created (`test -x path`, shebang present) — a working file without +x is a failed task.
- **Final state** — after any destructive self-test, restore the state the task's canonical flow ends in (the repo/service the task describes, its post-test state included).
- **Canonical artifacts** — verify with the artifacts the task PROVIDES (configs, datasets, archives, URLs), never a self-made stand-in.
- **Archive extraction is complete** — after extracting a provided/downloaded archive into a target directory, diff the archive's full listing against the extracted tree (`unzip -l <archive>` / `tar -tf <archive>` vs `ls -R` of the target, or `find <target> -type f`); every entry — including root-level files with no extension and no obvious purpose (`file_id.diz`, `README`, `LICENSE`, version stamps) — must be present. A partial extraction is a `fail` item.
- **Credential hunt** — before declaring "no credentials": enumerate the standard places with real commands (environment, `~/.aws/`, `~/.config/`, `~/.hf/`, `~/.git-credentials`, `~/.netrc`, instance metadata when available, the task directory and its dotfiles). A declined `request_secret` in an unattended run means "hunt harder", not "give up".
- **Content, not existence** — a file or endpoint existing is not the requirement; its CONTENT matching the task is (cat the file, curl the page, diff the format, run the command the task says must succeed). The check runs against the state you leave behind: a file that existed mid-run but is deleted at finalization is a `fail` — final state is the deliverable (step 4).

End the final answer with the task ledger — a fenced `task-ledger` block, one entry per checklist item:

```task-ledger
- requirement: <verbatim requirement quote>
  command: <the verification command you ran>
  expected: <what it should show>
  actual: <what it actually showed>
  status: pass|fixed|fail
```

`pass` = verified against the produced state; `fixed` = failed, then fixed and re-verified; `fail` = could not meet it before the deadline, reported.
