// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Returns the platform-specific OAuth launcher, or `null` when the default
/// `package:url_launcher` implementation should be used.
bool Function(String url)? createOpenRouterOAuthLauncher() => null;
