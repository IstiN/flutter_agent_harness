### Root Cause

A failed provider run lands its `[[auth-expired:codemie]]` error in the transcript as an actionable "Session expired — Authorize" card (`AgentService._finalizeAssistant` → `_authExpiredCard` in the shared chat tile). The re-auth flow completed (PR #593 fixed that), but `saveCodemieConnection` only reconfigured the service — clearing the top error banner while the stale card stayed in the transcript, still asking the user to authorize an already-refreshed session.

### Previous Attempt

PR #593 (issue #586) anchored the re-auth flow on the root navigator so the SSO prompts survive transcript rebuilds. The flow now succeeds, but nothing reconciles the transcript on success — which is what this issue reports.

### Fix

- `flutter_app/lib/services/agent_service_transcript.dart`: new `AgentService.resolveAuthExpiredCards()` — removes every transcript message carrying an `[[auth-expired:<id>]]` marker and drops one system note ("Authorization successful — … try sending your message again.") where the newest card was.
- `flutter_app/lib/services/codemie_sso_flow_steps.dart`: `saveCodemieConnection` calls it right after `service.reconfigure(config)` — one hook covers every success path (card Authorize tap, extension cookie sign-in, Settings re-login, onboarding).

### Test Coverage

- `flutter_app/test/services/codemie_sso_flow_steps_test.dart` — 2 new tests: a double-expiry transcript (2+ cards) resolves to a single note at the newest card's slot with neighbors untouched; a card-free transcript gets no stray note. Red before the fix, green after.
- `flutter_app` full suite: 2568 passed / 217 failed / 101 skipped — a baseline run of the same failing file set WITHOUT the fix produces the byte-identical 217 failures (all pre-existing `test/golden/*`, `test/cli_visual/*`, wasm-toolchain rendering failures of this bare Linux runner), so the fix adds zero failures.
- `flutter analyze`: 91 pre-existing infos before and after — no new issues. `packages/fa_ui` tile tests: 19 passed.

### Notes

- The card is a live-transcript artifact only: session reload projects the persisted record without an actionable card, so nothing resurrects after a restart.
- The extension relay panel (`relay_agent_service.dart`) already narrates its auto re-auth with system notes and auto-resend; it does not route through `saveCodemieConnection` and is left as-is.
