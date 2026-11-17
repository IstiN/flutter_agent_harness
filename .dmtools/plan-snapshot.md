# gh-2237 — Compaction basis collapse: one basis, honest receipts

One sentence: a post-run auto-compaction that prints `auto-compact start`
always ends with ≥1 visible fold pass or a terminal receipt stating why it
did nothing.

Root cause (RCA complete, owner-resolved): the CLI trigger gate measures a
usage-anchored basis (`agent_cli_compaction.dart:434`), then the structured
engine's `_refreshState()` → `refreshAgentState` blanket-zeroes every
assistant usage anchor (`engine.dart:172`) and re-derives a collapsed
chars/4 basis, exits under-trigger (`engine.dart:338-340`) with zero passes,
and the CLI's `onDone` logs nothing for `passes == 0`
(`agent_cli_compaction.dart:211`) → silent start-only loop.

## Tasks

### T1 — DONE: anchor-preservation tests (UT-1/UT-2/UT-3 → AC1/AC4) [x]
- `what`: new `test/compaction/structured_refresh_basis_test.dart`:
  UT-1 `refreshAgentState` preserves projection-curated anchors (estimate
  stays usage-anchored, not whole-list chars/4); UT-2 negative twin —
  anchors predating a compaction boundary still reset via the projection's
  `_resetStaleUsageAnchors` (no stale over-anchor); UT-3 basis-equality —
  the gate measurement and the engine's post-refresh `_requestTokens()`
  agree on the same list, both derivation orders, plus the never-anchored
  case (E2, agree by construction).
- `verify`: `dart test test/compaction/structured_refresh_basis_test.dart`
  — UT-1/UT-3 FAIL (blanket zeroing collapses the basis), UT-2 passes
  (boundary reset already exists — it is the guard).

### T2 — DONE: projection-trust in `refreshAgentState` (AC1, OQ1) [x]
- `what`: `lib/src/compaction/structured/engine.dart` — drop the
  `message.copyWith(usage: Usage.zero)` re-map; `state.messages =
  await session.buildContextMessages()` (the projection's boundary-keyed
  reset is the single anchor authority). Update the doc comment.
- `verify`: T1 file green; `dart test test/compaction/` +
  `dart test test/session/` green (gh-2097 semantics intact).

### T3 — DONE: engine exit-reason field (UT-4 engine half → AC3/OQ3) [x]
- `what`: tests asserting an unforced `StructuredCompactor.run()` on an
  under-trigger session returns true with a public `zeroPassReason`
  naming the deciding gate + basis/trigger numbers
  (`basis N below trigger M at the run gate`); a forced run leaves it
  null; a run that did passes leaves it unused (pass receipts tell the
  story).
- `verify`: new tests in `test/compaction/structured_engine_test.dart`
  (or a sibling) FAIL — no such field exists.

### T4 — DONE: instrument the under-trigger exit sites (AC3) [x]
- `what`: set `zeroPassReason` at every receipt-free zero-pass exit:
  the run gate (`:338`), hide-pass gate before-check (`:553`), hide-pass
  view==null (`:555`), checkpoint gate before-check (`:982`). Counts
  only, never content (repo rule).
- `verify`: T3 tests green; existing engine suites green.

### T5 — DONE: factory-level zero-pass receipt (UT-4 factory half → AC2) [x]
- `what`: `AutoCompactorFactory.run()` unforced + structured under-trigger
  → `hooks.onDone(0, tokens)` must now carry the engine's reason; forced
  zero-pass still falls through to the classic engine (gh-1742 pin, AC5).
- `verify`: new `test/agent/auto_compactor_zero_pass_receipt_test.dart`
  FAILS — `onDone` has no reason parameter.

### T6 — DONE: thread the reason through onDone [x]
- `what`: `AutoCompactorHooks.onDone(int passes, int tokens,
  {String? reason})`; the factory's structured outcome record gains the
  reason and forwards it on the zero-pass success branch; update every
  implementer mechanically: `lib/src/cli/agent_cli_compaction.dart`,
  `lib/src/task/task_executor.dart`,
  `flutter_app/lib/services/agent_service_compaction.dart`, and the test
  doubles (7 test files).
- `verify`: T5 green; `dart analyze` clean; existing auto-compactor and
  CLI compaction suites green.

### T7 — DONE: REG-1 signature detector + unit tests [x]
- `what`: pure helper `lib/src/compaction/receipt_scan.dart`:
  `compactionStartWithoutTerminalReceipt(lines)` — ≥2 consecutive
  `auto-compact start` diagnostics with no intervening terminal receipt
  (`auto-compact done|pass|retry`), including a trailing start, is the
  defect signature. Unit tests: the field signature (six starts, zero
  terminals) fails; healthy logs pass; interleaved pass lines are not
  terminal on their own… (they ARE activity, but the run must still close
  — adjacent-start pairs with only pass lines between count as covered
  activity per the pass vocabulary; the detector flags starts with
  NOTHING receipt-like between them).
- `verify`: `dart test test/compaction/receipt_scan_test.dart` green.

### T8 — DONE: CLI-level ITs (IT-2/IT-5/IT-3/REG-2) [x]
- `what`: new `test/cli/compaction_zero_pass_receipt_test.dart`:
  - IT-2: message-cap-armed funnel on a transcript under the token
    trigger (seeded caps sidecar, small learned cap) → fa.log shows
    `auto-compact start` then `auto-compact done passes=0 (no-op: basis N
    below trigger M at the run gate)`; FakeCliIO shows the dim user row;
    the fake stream records ZERO judge/checkpoint (compaction-lane)
    calls — observable, not silent.
  - IT-5/IT-1: anchored over-trigger transcript (fake provider reports
    usage on the last assistant turn) → unforced post-run run performs
    ≥1 pass (the lab cascade shape keeps folding; the old code
    zero-passed exactly here).
  - IT-3/REG-2: forced `/compact` on an under-trigger transcript still
    prints a visible fold (classic fall-through intact).
- `verify`: the new file FAILS pre-fix (IT-2: no terminal receipt; IT-5
  shape would zero-pass post-T2 only if anchors were still destroyed —
  with T2 landed IT-5 passes; IT-2/REG-2 pin receipts + immunity).

### T9 — DONE: CLI zero-pass terminal receipt (AC2/OQ2) [x]
- `what`: `_AutoCompactorCliHooks.onDone` — remove the `passes > 0`
  suppression: `passes > 0` keeps the byte-identical done line (E6);
  `passes == 0` emits
  `auto-compact done sid=… passes=0 (no-op: $reason)` on the diagnostic
  lane AND a dim user-facing row (boot-cap defer precedent; auto runs
  only — the manual path keeps its own note). Close the HEP
  `compaction_start` bracket with freed=0 when no pass reported
  (gh-1742's "brackets never stay open" contract).
- `verify`: T8 ITs green; `dart test test/cli/` compaction shards green.

### T10 — DONE: Full gate + deliverables [x]
- `what`: `dart format` touched files, `dart analyze` clean, run
  `test/compaction`, `test/agent`, `test/session`, `test/cli`
  (compaction/over-window shards) + the repo fast gate subset reachable
  in-suite; git completion guard; `outputs/gh-2237/response.md`.
- `verify`: analyze/format clean, targeted suites green, guard shows the
  commits, response.md written.

## Decisions

- **D6 (E4 shape — discovered during T8)**: the gh-1680 message-cap
  channel FORCES the structured engine (`capTriggered`), and a forced
  zero-pass falls through to the classic engine (gh-1742) whose pass and
  done receipts close the run. The cap-armed funnel was therefore never
  the silent shape; post-AC1 the unforced `passes=0` exit is unreachable
  from the CLI (gate and engine measure the same basis — the
  impossible-by-construction property this card installs). The
  `passes=0 (no-op: …)` receipt stays as defense-in-depth, pinned at the
  factory/hook level (UT-4); the CLI ITs pin receipt coverage (REG-1
  clean) on every reachable arming.
- **D7 (resume re-anchor)**: the CLI deliberately re-anchors loaded
  records at chars/4 on resume (`resetLoadedUsageAnchors`,
  session_commands.dart — a separate card's phantom-size fix), so the
  IT-5 lab shape sources its anchor from the LIVE turn's provider usage
  (which travels into the projection through the fresh turn's records) —
  exactly the six-runs-one-process field mechanism.


- **D1 (AC1/OQ1)**: projection-trust — delete the blanket `Usage.zero`
  re-map in `refreshAgentState`; no basis parameter, no new matching
  logic (`session_tree.dart:868-913` already boundary-key-resets stale
  anchors on every `buildContextMessages`).
- **D2 (OQ3 threading)**: engine exposes `zeroPassReason`; the factory's
  `_runStructured` outcome record carries it; the reason rides
  `AutoCompactorHooks.onDone` as an optional named `reason` — host-neutral
  (Flutter host gets a mechanical signature update, no parity work).
- **D3 (OQ2 surfaces)**: the zero-pass receipt prints on the diagnostic
  lane AND as a dim io row for auto-labeled runs; manual `/compact` keeps
  its existing no-op note.
- **D4 (HEP)**: zero-pass runs now close the `compaction_start` bracket
  (`compactionEnd(0)` when no pass reported) — brackets never stay open.
- **D5 (scope)**: classic-engine silent under-trigger head-gate is out of
  the card's named scope (structured is the default engine); untouched.

## Open questions

- None blocking. OQ1/OQ2/OQ3 were owner-resolved in the ticket; this plan
  implements exactly those resolutions.
