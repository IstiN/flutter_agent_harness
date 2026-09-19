# Re: 🟡 IMPORTANT: Flaky assertion — the painted done-row frame can be coalesced away

Fixed with your options 1 + 2 combined (`test/integration/theme_readability_pty_test.dart`):

1. **Mock delay between responses** — the scripted mock now sleeps 400 ms before answering requests `n >= 1`, so after each tool call settles the TUI idles a full frame interval before the next call starts. The settled done/failed frame can no longer be coalesced away.
2. **Poll instead of post-hoc assert** — the two `expect(raw, contains(bg(...)))` assertions are now `harness.waitForText(bg(...), timeout: 30s)` polls of the cumulative stream before `raw` is captured. If a frame were still never painted, the test now fails with a clear timeout + raw tail instead of a bare `contains` miss.

Verified with 14 consecutive `--tags integration` runs of the suite (12/12+ green; see response.md for the final count) — no recurrence of `does not contain '48;2;40;56;46'`.
