// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Writable "home" for the `~/.dap` layout on sandboxed mobile hosts.
///
/// Android/iOS app processes have no `HOME` and a read-only `/` cwd, so the
/// hub client's default (`${HOME ?? cwd}/.dap/config.json`) resolves to
/// `/.dap/config.json` and every save silently fails. The mobile sandbox
/// factory sets this to the app's `fah_sandbox` directory; desktop leaves it
/// null (real `~`).
///
/// Mutable-global ordering note: this is written ONCE by the mobile env
/// factory before any UI reads it (boot awaits `createEnv()`), and every
/// other construction site (the `dap_service_test.dart` seams, desktop
/// callers) passes an explicit `home:` — so test-order and read-order
/// coupling is currently safe. A test injecting only `environment:` still
/// inherits whatever a previous test left here; keep resetting it in
/// `tearDown`.
String? dapHomeOverride;

/// Resolves the home [IoDapHubService] should use: an explicit [home] wins,
/// then [dapHomeOverride], else null (the package default).
String? resolveDapHome(String? home) => home ?? dapHomeOverride;
