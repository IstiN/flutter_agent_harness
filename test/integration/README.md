# Fa CLI Integration Tests

End-to-end tests that spawn the Fa CLI (`dart run bin/fah.dart`) as a real
subprocess attached to a PTY, send keystrokes, and verify terminal output
through an xterm emulator.

## Running

```bash
dart test --tags integration
```

The `integration` tag is excluded from the pre-commit gate (see
`dart_test.yaml`); these tests are slow because every spawn JIT-compiles
the CLI. First-time boot can take up to ~90 s.

## Structure

- `pty_harness.dart` — PTY-based test harness (spawn, send keys, capture
  output, xterm screen model)
- `terminal_screenshot.dart` — renders the terminal screen as a PNG for
  vision verification
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
7. Screenshot: `await renderTerminalScreenshot(lines: harness.viewportLines, outputPath: '/tmp/test.png')`
8. Close: `await harness.close()` (registered via `addTearDown`)

## pty2 0.5.3 API notes

- `PseudoTerminal.start(exe, args, workingDirectory:, environment:, raw:)`
  — no size parameters; call `pty.resize(columns, rows)` right after start
  (default is 80x20).
- `pty.out` is a `Stream<String>` (already decoded); `pty.write(String)`.
- The child env inherits only TERM/LANG/LOGNAME/USER/DISPLAY/LC_TYPE/HOME/
  PATH from the parent plus the explicit `environment:` map — the harness
  passes `PUB_CACHE` through so `dart run` still resolves packages when
  `HOME` is overridden.
