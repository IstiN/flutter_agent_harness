# Fa CLI Integration Tests

End-to-end tests that spawn the Fa CLI (`dart bin/fah.dart`) as a real
subprocess attached to a PTY, send keystrokes, and verify terminal output
through an xterm emulator.

## Running

```bash
dart test --tags integration
```

The `integration` tag is excluded from the pre-commit gate (see
`dart_test.yaml`); these tests are slow because every spawn JIT-compiles
the CLI. First-time boot can take up to ~90 s.

Visual (screenshot) tests live in `flutter_app/test/cli_visual/` — they run
the same PTY harness but render every step through the real Flutter
`TerminalView` (JetBrainsMono, Fa palette) into
`test/integration/screenshots/NN_name.png` (+ `.txt` twins with the exact
screen text). Run them with:

```bash
cd flutter_app && flutter test test/cli_visual --tags integration
```

## Structure

- `pty_harness.dart` — PTY-based test harness (spawn, send keys, capture
  output, xterm screen model)
- `fa_cli_integration_test.dart` — test scenarios

## Writing new tests

1. Spawn: `final harness = await FaCliHarness.spawn(extraEnv: {'HOME': tempHome.path})`
   — always override `HOME` with a temp dir containing a minimal
   `.fah/config.yaml` so tests are isolated from the developer's real
   config and keys. `approvalMode: yolo` avoids approval gates.
2. Wait for boot: `await harness.waitForBoot()` — waits for the banner's
   `[Model]` block and lets the frame redraws settle. NOTE: in TUI mode the
   input zone renders NO `fa> ` prefix (that prompt is line-mode only), so
   never wait for `fa>` under a PTY.
3. Send keys: `harness.sendText('/command')`, `harness.sendEnter()`,
   `harness.sendArrowDown()`, `harness.sendEscape()`
4. Slash commands: prefer `await harness.runSlashCommand('/exit')` — in TUI
   mode typing a bare slash command opens the completion menu where Enter
   only accepts the highlighted item; `runSlashCommand` closes the menu
   with Escape first so Enter always submits. Commands WITH arguments
   (e.g. `/approval always-ask`) close the menu while typing and submit
   with a plain Enter.
5. Pickers (provider wizard, confirmations): arrows navigate, Enter
   selects, Esc cancels. Typing does NOT pick a numbered option in TUI
   mode — that's line mode only.
6. Assert: `expect(harness.screenText, contains('expected'))` (screen model)
   or match the raw stream via the `waitForText` return value.
7. Close: `await harness.close()` — kills the process and cancels the
   output subscription (an open subscription keeps the test runner's event
   loop alive and hangs the run).

## pty2 0.5.3 API notes

- `PseudoTerminal.start(exe, args, workingDirectory:, environment:, raw:)`
  — no size parameters; call `pty.resize(columns, rows)` right after start
  (default is 80x20).
- Spawn `dart bin/fah.dart`, NOT `dart run bin/fah.dart`: `dart run` spawns
  a separate child VM that escapes `pty.kill()` and keeps the PTY (and the
  whole test run) alive.
- `pty.out` is a `Stream<String>` (already decoded); `pty.write(String)`.
- The child env inherits only TERM/LANG/LOGNAME/USER/DISPLAY/LC_TYPE/HOME/
  PATH from the parent plus the explicit `environment:` map — the harness
  passes `PUB_CACHE` through so package resolution still works when `HOME`
  is overridden.
