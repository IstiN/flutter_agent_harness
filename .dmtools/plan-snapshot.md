# gh-2461 — plan (identical-tool-call loop guard + root-cause REG)

## Tasks

- [x] **T1 — Root-cause REG tests (refute candidates 1 and 2, pin the named mechanism).**
  - what: Three focused tests:
    (a) `test/providers/gh2461_finish_reason_error_replay_test.dart` — the
    transient ladder's handling of the vendor `finish_reason: "error"` word:
    pin that `finishReasonRetryClass` classifies it transient (unknown word
    default) AND that a pre-commit `finish_reason: error` replay appends NO
    duplicate assistant+toolResult pair (harness-level probe: scripted
    stream → tool call → error turn → replay → same call → text; transcript
    grows exactly +2/turn, each call executed once). This is the
    failing-first trigger repro: it also demonstrates the run survives the
    identical repeat forever today (the guard gap).
    (b) `test/agent/gh2461_custom_record_projection_test.dart` — projection
    test on a session carrying `model_request_summary` +
    `shell_job_registry` custom records (gh-2423 seam): classic projection
    AND structured projection (hidden-range + checkpoint present) must
    render zero custom-record JSON into the model context.
  - verify: `dart test test/providers/gh2461_finish_reason_error_replay_test.dart test/agent/gh2461_custom_record_projection_test.dart` green; (b) FAILS if the invariant broke (mutation-check by hand once).

- [x] **T2 — Loop guard module (`lib/src/agent/loop_guard.dart`).**
  - what: Pure detector: recursive-sorted-key JSON normalization of tool
    args; per-assistant-turn identity key (ordered list of [name,
    normalizedArgs] over the message's ToolCall blocks; null when the
    message has no tool calls → reset); `IdenticalCallGuard` state machine
    (streak, notice-once latch, exempt handling, reset-on-user-message).
    Notice text rides the `<system-notice>` envelope (machine content);
    abort error text names the tool, the streak length and the re-plan
    instruction.
  - verify: `dart analyze lib/src/agent/loop_guard.dart` clean.

- [x] **T3 — Loop wiring + config knobs (`lib/src/agent/agent_loop.dart`).**
  - what: `AgentLoopConfig` gains `identicalCallNoticeThreshold` (default
    5; 0 disables the guard), `identicalCallAbortThreshold` (default 8;
    ≤0 disables abort), `identicalCallExemptTools` (const {}).
    `_runAgentLoop` accepts the turn verdict after
    `_retryDegenerateEmpty`/terminal check: notice → queued as a pending
    injection (rides the next request, never counts as a steering
    extension); abort → run ends with the honest error terminal BEFORE the
    duplicated tool phase executes (no further provider calls). Streak
    resets on injected user/steering messages and on tool-free assistant
    turns. `Tool`/`AgentTool` gain no field; exemption is by tool NAME
    (config set) — call-site opt-out for watch/polling tools.
  - verify: `dart analyze lib/src/agent/` clean.

- [x] **T4 — Guard tests (`test/agent/loop_guard_test.dart`).**
  - what: streak detection (identical key); notice injection behavior
    (message in the next request's context, once); abort behavior (error
    terminal, executor call count bounded); NO false positives on
    legitimately repeated calls with DIFFERENT args (20 alternating
    turns); opt-out via exempt tool name (no trip on 10 identical exempt
    calls); streak reset on a steering message between identical calls;
    guard disabled via threshold 0; normalization order-insensitivity
    ({a,b} vs {b,a}).
  - verify: `dart test test/agent/loop_guard_test.dart` green, red-first
    confirmed against the pre-T3 loop (scratch probe already red).

- [ ] **T5 — Full suite + outputs.**
  - what: `dart test` (deterministic set, no live models), fix any
    regression; write `outputs/rca.md`, `outputs/response.md`; update the
    CHANGELOG `## Unreleased`.
  - verify: full `dart test` green; outputs written.

## Decisions

- **Root cause (named mechanism, "other" per the ticket's menu):** the
  vendor `finish_reason: "error"` word is UNKNOWN to the classification
  table (`types.dart` `_transientFinishReasons`/`_terminalFinishReasons`)
  and the #312 default sends unknown words to TRANSIENT — the transient
  ladder silently replays the identical request (the clip's
  `[net] connection lost (Provider finish_reason: error) — retrying`
  proves the class fired inside the loop window). The replay is
  transcript-clean (no duplicate pairs — refuted candidate 1), the custom
  records never project (refuted candidate 2), so each loop turn gave the
  model one more identical-context decode with zero harness signal —
  and NOTHING detects the identical-call streak. The unbounded burn is
  the missing loop guard; the guard is the fix (per the ticket: "do
  regardless of root cause"). Candidate 3 (slim manifest) is a
  request-shape change, not a loop mechanism — documented, no A/B
  possible in this environment (single squashed commit; pre-upgrade
  build unavailable).
- **Guard thresholds:** notice at 5 consecutive identical turns, abort at
  8 (3 more after the notice) — inside the ticket's suggested 4–6 window
  for the notice, honest terminal after a fair retry.
- **Opt-out granularity:** per tool NAME via
  `AgentLoopConfig.identicalCallExemptTools` — call-site opt-out for
  polling/watch tools without touching the `Tool` wire type.
- **Notice channel:** synthetic `<system-notice>` user message injected
  at the turn boundary (the gh-2423 C3 pending-notice mechanism's shape);
  never counted against `maxSteeringTurns`.
- **Abort semantics:** ends the run with `StopReason.error` whose message
  names the repeated call; happens BEFORE the duplicated tool batch
  executes (the run stops burning provider calls at the first repeated
  call past the notice).


## Decision addendum (T4 outcome)

- The guard verdict is OUTCOME-aware and lands after the tool phase: turns whose every call failed are the tool-misuse breaker's jurisdiction (issue #862 — its own identical-call ladder pins behavior in misuse_breaker_test.dart IT-3) and never advance the streak. The guard owns identical-call-SUCCEEDS degeneration. Abort semantics therefore execute the 8th identical exchange once and end the run before the 9th provider call.

## Open questions

- The owner-local repro assets (6.3 GB session JSONL, the clip file) are
  not present in this environment — the REG comparison runs on
  constructed windows (scripted streams + synthetic session trees), not
  the recorded session. Documented in the RCA; no assumption is made
  about the session's exact content.
- Whether `finish_reason: "error"` should become TERMINAL in the
  classification table is NOT decided here (changing unknown-word
  defaults is a behavior policy call above this leg's scope); the guard
  bounds the damage provider-agnostically instead.
