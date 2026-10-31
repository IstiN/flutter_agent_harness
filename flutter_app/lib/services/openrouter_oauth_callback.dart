// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The desktop OAuth localhost callback server lives in the core CLI
/// package (`openrouter_oauth_server.dart`, gh-781 chain-safe close
/// adopted back from this app's pre-fork body, issue #1996); this shim
/// keeps the app's existing import paths working.
library;

export 'package:flutter_agent_harness/io.dart'
    show OpenRouterOAuthLocalCallbackServer;
