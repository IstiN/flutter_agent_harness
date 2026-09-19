**Fixed.** Two-part de-flake in `test/integration/theme_readability_pty_test.dart`:

1. `_ScriptedMockServer` now delays **400 ms** before answering every chat request with `n >= 1` (the boot-time `/models` turn still answers instantly), so the settled done/failed frame is always emitted while the TUI idles waiting for the model — the run→settle frame-coalescing window this thread describes is closed at the source.
2. Both tint assertions are now `harness.waitForText(...)` polls (30 s timeout) for the exact tint SGR sequence, instead of post-hoc `contains` on the accumulated stream after `scenario-complete`.

The reported failure (`dracula: … does not contain '48;2;40;56;46'`) never recurred across 18 consecutive green `--tags integration` runs after the change, and the round-2 review independently verified the suite 3/3. The "both tints really painted" precondition stays hard (not softened) — with the delay it is deterministic, and it is what guards the SGR state-machine contract from passing vacuously.
