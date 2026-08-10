// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// No-op stub for platforms that do not use deep links or `postMessage`.
Future<void> attachOpenRouterOAuthLinks() async {}

/// No-op stub: verifier persistence is only needed on web for the redirect
/// flow.
void storeOpenRouterOAuthVerifier(String state, String verifier) {}

/// No-op stub: redirect completion is only needed on web.
Future<String?> completeOpenRouterOAuthFromRedirect() async => null;
