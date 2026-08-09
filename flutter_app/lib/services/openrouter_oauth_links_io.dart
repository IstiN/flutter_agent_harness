// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:app_links/app_links.dart';

import 'package:fa/services/openrouter_oauth_coordinator.dart';

/// Attaches the `fah://oauth/openrouter` deep-link listener for mobile
/// builds (iOS/Android).
Future<void> attachOpenRouterOAuthLinks() async {
  final appLinks = AppLinks();

  void handleUri(Uri? uri) {
    if (uri == null) return;
    if (uri.scheme == 'fah' &&
        uri.host == 'oauth' &&
        uri.path == '/openrouter') {
      OpenRouterOAuthCoordinator.instance.complete(uri.queryParameters['code']);
    }
  }

  appLinks.uriLinkStream.listen(handleUri);
  try {
    handleUri(await appLinks.getInitialLink());
  } on Object {
    // Deep-link retrieval is best-effort; a failure here must not block
    // app startup.
  }
}
