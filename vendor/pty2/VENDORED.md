# Vendored: pty2

- **Upstream**: https://github.com/jtmcdole/termui/tree/main/packages/pty2
  (pub.dev `pty2 0.5.7`, MIT — see LICENSE).
- **Why vendored**: gh-2208 — pty2's `BlockingPseudoTerminal` runs a
  `_waitForExitCode` isolate blocked in a native FFI `waitpid` with no
  timeout. While a PTY child lives, that isolate can neither reach a
  safepoint nor answer the Dart VM's exit-time check-in handshake, so the
  whole `dart test` process wedges forever
  (`Attempt:N waiting for isolate _waitForExitCode to check in` — CI runs
  43835937617 / v1.0.735 and 43151400571 / PR #2121; tracker issue #2122).
  The PTY test harness (`test/integration/pty_harness.dart`) needs the
  child pid to SIGKILL-escalate when the cooperative `kill()` (SIGTERM +
  SIGHUP, once-only per pty2's `_killed` flag) does not reap the child
  within its grace window — otherwise a leaked child turns the CI leg
  into a 40-minute zombie.
- **Patch vs upstream 0.5.7** (the only diff): the `pid` getter is exposed
  end-to-end — `PtyCore.pid` + `PseudoTerminal.pid` interface members,
  `BasePseudoTerminal.pid`/`PtyCoreUnix.pid` delegating to the existing
  private `_pid`, and `PtyCoreWindows.pid` via `GetProcessId(_hProcess)`
  (upstream's commented-out shape returned the process HANDLE, not the
  pid). `pubspec.yaml`: dropped the upstream `resolution: workspace`
  marker (this repo is not a pub workspace). Everything else is verbatim.
- **Consumers**: the root package's dev_dependencies (`pubspec.yaml`,
  `pty2: {path: vendor/pty2}` — staged like `vendor/xterm`, CI run
  43851264755); `flutter_app` keeps the hosted 0.5.7 — behavior identical,
  the patch adds getters only.
- **Un-vendor when**: upstream exposes `pid` in a release; bump the
  dev-dep back to the hosted constraint and delete this directory.
