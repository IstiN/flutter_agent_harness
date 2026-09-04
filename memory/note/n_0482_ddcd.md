---
id: "n_0482_ddcd"
type: "note"
title: "PTY integration test gotchas (fa_cli_integration_test.dart): (1) pty_harness spawns the binary via ABSOLUTE path since the folder-scoping test — spawn(workingDirectory:) can now point at temp dirs; (2) the fa child's stderr is INHERITED by the dart test runner (not captured by the PTY) — usable as a debug channel via stderr.writeln in bin/fah.dart; (3) TUI slash-command dispatch under `dart test` can take >10s to reach persistence callbacks — poll for side effects up to ~30s; (4) macOS: resolve temp dirs with resolveSymbolicLinksSync() (/var → /private/var) or the child's getcwd slug won't match the test's paths; (5) a failing PTY test can wedge the whole runner (child processes survive --timeout) — pkill -9 -f bin/fah.dart to clean up."
author: "agent"
date: "2026-09-02T11:55:18.992216Z"
area: "project"
topics: []
source: "agent"
accessCount: 0
importance: 0.5
tags: ["#note", "#source_agent", "testing", "pty", "gotchas", "integration"]
---


# Note: n_0482_ddcd

PTY integration test gotchas (fa_cli_integration_test.dart): (1) pty_harness spawns the binary via ABSOLUTE path since the folder-scoping test — spawn(workingDirectory:) can now point at temp dirs; (2) the fa child's stderr is INHERITED by the dart test runner (not captured by the PTY) — usable as a debug channel via stderr.writeln in bin/fah.dart; (3) TUI slash-command dispatch under `dart test` can take >10s to reach persistence callbacks — poll for side effects up to ~30s; (4) macOS: resolve temp dirs with resolveSymbolicLinksSync() (/var → /private/var) or the child's getcwd slug won't match the test's paths; (5) a failing PTY test can wedge the whole runner (child processes survive --timeout) — pkill -9 -f bin/fah.dart to clean up.

**By:** [[agent]]
**Date:** 2026-09-02T11:55:18.992216Z
**Area:** [[project|project]]
