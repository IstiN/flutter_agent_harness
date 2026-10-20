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
String? dapHomeOverride;

/// Resolves the home [IoDapHubService] should use: an explicit [home] wins,
/// then [dapHomeOverride], else null (the package default).
String? resolveDapHome(String? home) => home ?? dapHomeOverride;
