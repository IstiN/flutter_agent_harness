# gh-2492 plan — GOAL #29 remainder (C2/C4/C5/C6/C7)

Base: 7bbf8eb (origin/main). Branch: ai/gh-2492.

## Tasks

### T1 [done] — C2 core: pin records in `task_executor.dart`
- **what**: Write `SegmentPinRecord(pinned: true)` for (a) the task prompt
  record of a fresh spawn (pinned once, after its first transcript flush);
  (b) every steering delivery — pin the new record(s), release the previous
  delivery's records (one steering delivery pinned at a time); (c) the
  resume path runs "ensure pins" once over the loaded session: pin the first
  prompt record and the newest steering record if not already pinned; never
  unhide anything already hidden. Mechanism: track pending pin message
  identities in the executor; the transcript flush (single writer) resolves
  them to record ids via `appendMessage` and appends the pin records.
  REG-6: `isSyntheticUserText` untouched.
- **verify**: `dart test test/task/` — new failing-first tests in
  `test/task/subagent_steering_pins_test.dart`: fresh spawn pins the prompt
  record; steering delivery pins newest + releases previous; resume
  ensure-pins a pre-card session; `_isRealUserTurn` semantics unchanged
  (existing tests stay green).

### T2 [done] — C2 belt: the trim valve honours pins
- **what**: `localTrimValve` gains an optional `pinnedMessages` parameter —
  messages carried verbatim behind the cut (after the turn/summaries/mail
  carries). The session-backed callers (`AutoCompactor._localTrimFallback`,
  `emergency_relief`) pass the session's pinned MessageRecords' messages
  (pinned records are visible by construction — hide tiers skip them);
  CLI callers pass nothing (unchanged shape).
- **verify**: new tests in `test/compaction/`: valve keeps the pinned task
  prompt + newest steering behind the cut; relief/valve drop them never;
  existing valve tests stay green.

### T3 [done] — C4: dedicated `ledger_budget.dart` + projection wiring
- **what**: Extract the hidden-ids ledger budget into
  `lib/src/compaction/ledger_budget.dart`: `hiddenLedgerBudgetTokens = 1000`,
  run detection over rendered hidden markers (contiguous seq runs, no
  visible record between), oldest-first collapse into
  `N records hidden [expand a-b]` until under budget, computed at RENDER
  time in `renderStructuredMessages` (no file rewrite; deterministic labels
  derived from covered records). Checkpoint markers/text stay out of the
  budget. Honest notice numbers unchanged (N counts the pass's hidden ids).
- **verify**: new `test/compaction/ledger_budget_test.dart` (unit: budget
  merge loop, 2+ ranges, boundary at the cap) + projection tests: markers
  of a request ≤ budget after multiple hides; expand door still resolves
  the same ids (REG-2/3 shapes).

### T4 [done] — C5: histogram labels on the hide-only path
- **what**: The four bare hide writers (judge hide, deterministic fallback,
  LRU re-hide in `structured/engine.dart`, `EmergencyRelief`) write
  `consolidated: true` with a per-range engine-generated histogram label
  (`bash ×61 · read ×40 · edit ×12 · 12:41–13:44`) computed from the
  covered records — no model text, no injection surface. The collapsed
  render-time markers (T3) derive the same label shape from their records.
- **verify**: tests: each writer's range carries `consolidated: true` +
  a histogram label; projection renders `<label> [expand a-b]`; the
  un-collapsed growth case — 4 cycles of hides stay bounded under the C4
  cap (the ≈18k rejection case stays bounded).

### T5 [done] — C6: one-window catalog/consistency check
- **what**: REG test proving trigger, over-window guard, both notices and
  the meter resolve the SAME window for (a) a catalog-only identity and
  (b) a registry-pinned one — every consumer through
  `resolveCompactionHostWiring(...).window` / `effectiveContextWindow`
  semantics. Production change only if a divergent path exists (none found
  so far: guard, meter, notices, trigger all funnel the shared seams).
- **verify**: `dart test test/compaction/one_window_test.dart` green.

### T6 [done] — C7: agent prompt rules
- **what**: New `prompts/compaction/pinned_steering.md` — the pinned-
  steering rule: what C2 pins (task prompt + newest steering of a child),
  so a parent does not re-send steering just to keep it visible; how to
  read the honest notices; pointer to the working-set contract. Generate
  with `dart run scripts/gen_prompts.dart`; include in the CLI system
  prompt and the task-child system prompt (beside working_set +
  context_hygiene). `prompts_sync_test.dart` gates drift.
- **verify**: `dart test test/prompts/` green; generated `.g.dart` updated.

### T7 [done] — docs + changelog + gates + close-out
- **what**: `docs/compaction.md` sections per component; changelog entries
  (`changelog/entries/gh-2492-*.md` per repo convention — CHANGELOG.md is
  a generated index, never hand-edited); run analyze + targeted suites +
  quality gates; completion guard; `outputs/gh-2492/response.md`.
- **verify**: `dart analyze` clean; `dart format` clean; targeted tests
  green; `git log origin/main..HEAD` non-empty.

## Decisions
- One branch, one commit per component (independently reviewable; the
  pipeline opens one PR — the ticket's "one PR per component preferred"
  is satisfied component-by-component at commit granularity).
- Pin bookkeeping lives in the executor's flush (single writer) keyed on
  message-object identity — robust against notice interleaving and the
  post-compaction flush-cursor reset (#387).
- The ledger budget is enforced at RENDER time only (per §C4: "no file
  rewrite") — the session file keeps bare ranges; determinism comes from
  deriving labels from covered records.
- Histogram labels are engine-generated strings (tool-name histogram +
  time span), never model text (C5: no injection surface).

## Open questions
- glm-5.4 context-window probe (#2423 C6 one-off verification): requires
  live z.ai credentials — NOT available in this leg; recorded as a concern,
  the catalog is left untouched (C6 here covers the invariant + test only).
