# Issue #157 — DAP e2e family: three reds, only one real (the other two were #152's races)

- **Issue:** https://github.com/IstiN/flutter_agent_harness/issues/157
- **PR (the one real fix):** https://github.com/IstiN/flutter_agent_harness/pull/160
- **Sibling that covered the other two cases:** https://github.com/IstiN/flutter_agent_harness/pull/158 (issue #152)
- **Date:** 2026-09-11
- **Surface:** `browser_ext/e2e/dap-multi-hub.spec.ts` (exists only on the `dap-slash-flow` branch, PR #145)

## Symptom

Three "reproducible, not flaky" Playwright failures reported as one family:

1. `dap-multi-hub.spec.ts:8` — `TimeoutError: page.waitForURL **/app/index.html` (20 s) on `dap-slash-flow` (runs 34614450400, 34626160992); blocked #145's required checks.
2. `dap.spec.ts` DM test — `expect(received).toContain(...)` on main (run 34610300389).
3. `journey-sessions.spec.ts` — `expect(received).not.toBe(expected)` (`sessionB == sessionA`) on main, same run.

## Triage first (this was the whole game)

Two of the three were already root-caused by #158's five-race audit of the
same suite:

- **case 2** = #158 race #5 — the DM test prompted after a fixed 5 s sleep;
  on a loaded runner the mock's one-shot `dap_dm` reply fires before the
  CLI's DAP handshake completes, the tool call errors, nothing re-sends →
  transcript lacks the DM (`toContain`) or the `relayTargets` poll times out.
  Run 34610300389 is among #158's own failing-first evidence.
- **case 3** = #158 race #4 — op acks awaited on stale collectors match an
  earlier `attached` row; `attach(null)` re-adopted session A
  (`sessionB == sessionA`), literally the shape #158 quotes.
- **case 1** = NOT covered: `dap-multi-hub.spec.ts` exists only on
  `dap-slash-flow`; #158 touches main-side specs only, so rebasing #145 onto
  post-#158 main heals nothing here.

Proof the reported "relay/CodeMie semantics" suspicion was wrong for case 1:
the test died at the URL wait before executing a single `hub.*` assertion.

## Root cause (case 1)

The spec unconditionally awaited the panel's app redirect
(`**/app/index.html`). The **default** Headless Chrome job builds without
`--with-app`: no bundle → `panel.js` HEAD-probe keeps legacy `panel.html` →
the wait is a deterministic 20 s timeout. Same-run evidence that the bundle
was absent: `no app build → legacy fallback renders` and both panel-focus
tests passed (all three cannot pass in an app build). Inverse flavor of
#158's race #1 (which skipped legacy-composer tests when the bundle IS
present).

## Fix

Gate the settle-wait on the bundle **file**
(`browser_ext/panel/app/index.html`) — never on `FA_E2E_WITH_APP` — mirroring
#158's guard convention. Everything the spec drives
(`chrome.runtime.sendMessage` / `chrome.storage.local`) works from either
panel flavor, so instead of skipping the default job the spec now runs green
in **both** jobs (bookmark/secret semantics get double coverage). The
app-flavor branch is byte-identical to the old wait.

After #158 lands, `helpers.appBundlePresent`/`awaitPanelSettled()` can absorb
the inline probe when the branch next merges main.

## Evidence

- Failing-first reproduced 1:1 locally (default no-bundle build):
  `waitForURL` timeout at `dap-multi-hub.spec.ts:13`; after the fix
  `1 passed (800 ms)`; full default-flavor suite 17 P / 4 S, no collateral.
- Dispatch 34637091163 on the fix branch: default Headless Chrome suite ✅;
  app job dap-multi-hub ✅ (its only reds were panel-focus ×2 — #158 race #1,
  the expected residual on a pre-#158 branch).
- Post-squash-merge, #145's `Browser extension` run 34637888840 on
  `dap-slash-flow`: 21 passed, dap-multi-hub included — the blocker is gone.

## Lessons

- A PR into a non-default base gets **no** `pull_request`-filtered checks
  (`browser-ext.yml` filters `branches: [main]`) — prove such branches with
  `workflow_dispatch` runs instead.
- Guard e2e flavor assumptions on the **artifact on disk** (the bundle
  file), not on env vars; the panel redirects on the file, the env var only
  names the CI job (same lesson #158 codified in `helpers.appBundlePresent`).
- Specs that only need extension-origin APIs (`chrome.runtime`,
  `chrome.storage`) don't need the app build at all — driving them from the
  legacy panel doubles CI coverage for free.
- A test that times out on its first line exonerates everything after it:
  read the failing line before suspecting recent product changes.
- Local-only dap e2e failures on a cold box can be the CLI agent's `dart
  run` first-compile outrunning the 60 s enrollment poll — the same
  enrollment-vs-timeout mechanism #158 race #5 names; CI pre-warms and
  passes. Classify before chasing.
- Squash-merged PR branches break `git merge-base --is-ancestor` checks on
  the original commit shas; verify landed content by diff/path, not
  ancestry.
