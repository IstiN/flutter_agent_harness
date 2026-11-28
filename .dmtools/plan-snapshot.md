# gh-2470 — deterministic per-history provider failures: classify as probable overflow

## Root cause (short)
`finish_reason: error` classifies as UNKNOWN (#312) → defaults to transient → the
ladder replays the identical request 3× and the exhaustion terminal advises
"Check the provider status or try again later" — wrong for a deterministic
per-history failure on a huge request (the ticket's ~245k-token session).

## Tasks

- [x] **T1 — RED ladder test** (`test/providers/probable_overflow_ladder_test.dart`):
  fake provider fails any request estimated above N tokens with
  `Provider finish_reason: error`. Assert (a) exactly 3 attempts (configured
  retries), (b) the terminal classifies probable overflow (marker present), (c)
  the advice says compact (/compact) or switch model/session and does NOT say
  "try again later"; discrimination cases: small request → generic exhausted
  terminal (retry advice stays), transient wording (connection reset) on a
  large request → generic exhausted terminal, differing error texts → generic.
  verify: `dart test test/providers/probable_overflow_ladder_test.dart` → FAILS.
- [x] **T2 — classifier + ladder integration**: new pure module
  `lib/src/probable_overflow.dart` (marker constant + recognizer, deterministic
  wording gate, large-request gate, self-contained token estimate) and
  `transient_retry_stream.dart`: track per-attempt failure texts; on transport
  budget exhaustion with identical deterministic texts on a large request, emit
  the probable-overflow terminal instead of `_exhausted`. Export from the
  barrel (append-only group, path-sorted).
  verify: T1 passes; `dart test test/providers/transient_retry_stream_test.dart
  test/overflow_test.dart` green (no regressions in the ladder).
- [x] **T3 — console category**: `classifyProviderFailure` renders the
  probable-overflow category for the marker terminal (compact/switch recovery),
  keeping "never a wrong category" for everything else.
  verify: unit tests for the classifier (marker line renders; other inputs
  unchanged).
- [x] **T4 — host relief funnel**: `_contextStopContinuationArmed` arms the
  over-window continuation funnel on probable-overflow stops too (persist →
  auto-compact → continue), so a following «continue» never re-sends the
  byte-identical poisonous history without a relief attempt (AC d). E2E test:
  poisoned main-model fake (fails > N tokens), healthy smol-role summarizer,
  boot history above N with a lying catalog window → the turn auto-compacts and
  completes.
  verify: `dart test test/cli/agent_cli_probable_overflow_continuation_test.dart`.
- [ ] **T5 — full gates**: `dart format`, `dart analyze`, full `dart test`
  (deterministic set), review `git status`.
  verify: all green; outputs/response.md written.

## Decisions
- Classification lives in a new top-level pure module (`probable_overflow.dart`,
  next to `overflow.dart`), NOT in compaction: providers must not depend on the
  compaction layer; the ladder already sits below it.
- Large-request gate: `tokens >= max(0.5 × window, 200_000)` — window-aware for
  small-window models, absolute floor for the ticket's family (catalog says 1M,
  the endpoint really fails far below). Unknown window (≤ 0) → floor only.
- Deterministic = every pre-commit failure in the chain carried the IDENTICAL
  error text, and the wording is neither transport-healable, rate-limit,
  budget, nor a definite overflow pattern (those paths own their failures and
  never exhaust the ladder).
- The optional gh-1742 verified-window feedback is NOT in this fix's scope
  (acceptance marks it Optional); the marker gives hosts the hook to add it.

## Open questions
- None blocking.
