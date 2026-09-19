# gh-671 — PR #674 rework: review findings fixed

## Issues/Notes

- 🚨 **BLOCKING (thread 6): unresolved merge-conflict markers committed** in `input/gh-671/ticket.json` (invalid JSON), `input/gh-671/ticket.md`, `input/ticket.md`.
- 🟡 **IMPORTANT (threads 1/8, 7):** flaky PTY assertion (painted done-row frame can be coalesced away); runner artifacts (`input/gh-671/pr_diff.txt`, `pr_info.md`) committed into the PR.
- 🔵 **SUGGESTIONS (threads 2–5, 9–12):** 3:1 label floor not checked on `toolSuccessBg`; truncated selected picker rows lose the accent wrap + stale comment; new `curly_braces_in_flow_control_structures` analyzer info; stale "byte-identical" doc on `kDefaultTuiTheme`.
- Note (from the general review): the new `fa_tui_fuzzy_roles_test.dart` test mutated the global `FaThemeController` with no reset — also fixed this round.

## Approach

**BLOCKING — conflict markers (thread 6).** The three files were unmerged in the `main` merge. Resolved each to the most complete ticket state (description + full `## Machine jobs` section: dev + both review runs) and staged them. `git diff --check` is clean and `json.loads` now parses `input/gh-671/ticket.json`.

**IMPORTANT — runner artifacts in the PR (thread 7).** `input/gh-671/pr_diff.txt` and `input/gh-671/pr_info.md` (self-referential artifacts that grow every factory run) are removed from the PR via `git rm`. The source fix belongs to the factory's auto-save step (only `git add` intended paths, or gitignore `input/` on job branches) and cannot be done from inside this PR.

**IMPORTANT — flaky PTY assertion (threads 1/8).** Two-part de-flake of `test/integration/theme_readability_pty_test.dart`, per the review's first two suggestions:
1. The scripted mock now delays **400 ms** before answering requests `n >= 1`, so after a tool call settles the TUI idles a full frame interval before the next call starts — the settled done/failed frame can no longer be coalesced away.
2. The `toolSuccessBg`/`toolErrorBg` `contains` assertions are now `waitForText` polls (30 s timeout) of the cumulative stream; a never-painted frame would fail with a clear timeout + raw tail instead of a bare `contains` miss.
Verified: 20+ consecutive green runs of the suite on this runner after the change (previously 1 failure in 3 runs).

**Suggestions (threads 2–5 / 9–12), TDD:**
- **Label floor on both tints:** the 3:1 matrix in `tui_theme_test.dart` now checks `toolTitle` over `toolSuccessBg` *and* `toolErrorBg` for all 7 built-ins. All palettes already clear it — enforcement gap closed, no value changes.
- **Truncated selected rows:** `_menuItemRow`'s truncated branch now wraps the fitted plain label in `_rearmSelection` (the stale "no-op" comment replaced). New regression test (`fa_tui_fuzzy_roles_test.dart`, `termWidth: 20`, 22-cell label) asserts the accent SGR opens after the `▸` glyph and immediately before the fitted label cells — failed pre-fix, passes post-fix.
- **Analyzer info:** the `loadUserThemes` guard got braces; `dart analyze lib/src/cli/tui_theme.dart` is back to the 2 pre-existing `implementation_imports` infos (parity with `main`).
- **Stale doc:** `kDefaultTuiTheme`'s comment no longer promises byte-identity; it states the explicit `toolOutput` fg was added in gh-671 and the old invariant is deliberately broken.
- **Test hygiene:** the fuzzy-roles test now restores the global controller with `addTearDown(controller.reset)`, removing file order-dependence.

## Files Modified

- `input/gh-671/ticket.json`, `input/gh-671/ticket.md`, `input/ticket.md` — conflict markers resolved, staged.
- `input/gh-671/pr_diff.txt`, `input/gh-671/pr_info.md` — removed from the PR.
- `lib/src/cli/fa_tui_rows.dart` — truncated selected labels wear the selection accent; comment updated.
- `lib/src/cli/tui_theme.dart` — braces on the `loadUserThemes` guard; `kDefaultTuiTheme` doc updated.
- `test/cli/tui_theme_test.dart` — label floor checked over both tool tints; interpolation lint cleaned.
- `test/cli/fa_tui_fuzzy_roles_test.dart` — new truncated-selection regression test; global controller reset teardown.
- `test/integration/theme_readability_pty_test.dart` — mock delay + tint polling (de-flake).
- `outputs/review_replies/thread_{1..12}.md`, `outputs/review_replies.json` — one reply per open inline thread.

## Test Coverage

- `dart test test/cli` → **2297 passed, 6 skipped** (includes the new truncated-selection regression test and the extended floor matrix).
- `dart test --tags integration test/integration/theme_readability_pty_test.dart` → **4/4 passed, 20+ consecutive runs** after the de-flake (mock delay + polling); the previously flaky `does not contain '48;2;40;56;46'` failure did not recur.
- `dart analyze` on all touched files → only the 2 pre-existing `implementation_imports` infos (same as `main`).
- `dart format` clean on all touched files.
