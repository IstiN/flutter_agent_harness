// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:fa/services/oauth_deep_link_router.dart';
import 'package:fa/services/openrouter_oauth_coordinator.dart';

/// The app's SINGLE `AppLinks` construction (issue #2395): every
/// custom-scheme deep-link consumer goes through [oauthDeepLinkRouter],
/// armed once by [attachOAuthDeepLinks].
AppLinks? _sharedAppLinks;
AppLinks get sharedOAuthAppLinks => _sharedAppLinks ??= AppLinks();

/// The shared `fah://oauth/*` router. Pure Dart and stateless across
/// boots — flows register/unregister their routes on it at runtime.
final OAuthDeepLinkRouter oauthDeepLinkRouter = OAuthDeepLinkRouter();

/// Whether [uri] is the OpenRouter OAuth callback (exact path, as
/// registered in the Android intent-filter and the iOS URL scheme).
bool _isOpenRouterOAuthDeepLink(Uri uri) =>
    uri.scheme == 'fah' && uri.host == 'oauth' && uri.path == '/openrouter';

/// Attaches the mobile deep-link listener for OAuth callbacks: the ONE
/// `AppLinks` subscription, routed per flow by [oauthDeepLinkRouter]
/// (`fah://oauth/openrouter` → the OpenRouter coordinator,
/// `fah://oauth/network` → whatever Networks receiver registers).
Future<void> attachOAuthDeepLinks() => attachOAuthDeepLinksForLinks(
  links: sharedOAuthAppLinks.uriLinkStream,
  getInitialLink: sharedOAuthAppLinks.getInitialLink,
);

/// Wires the shared router to a platform link stream — the injectable
/// seam for tests; production callers use [attachOAuthDeepLinks].
@visibleForTesting
Future<void> attachOAuthDeepLinksForLinks({
  required Stream<Uri> links,
  required Future<Uri?> Function() getInitialLink,
  OAuthDeepLinkRouter? router,
}) async {
  final linkRouter = router ?? oauthDeepLinkRouter;
  linkRouter.register(
    OAuthDeepLinkRoute(
      flow: 'openrouter',
      matches: _isOpenRouterOAuthDeepLink,
      onLink: (uri) => OpenRouterOAuthCoordinator.instance.complete(
        uri.queryParameters['code'],
      ),
    ),
  );

  void handleUri(Uri? uri) {
    if (uri != null) linkRouter.dispatch(uri);
  }

  // Subscribe to the link stream BEFORE checking the initial link — a
  // link delivered in between is dropped (broadcast streams drop events
  // with no listener) and `getInitialLink` returns null on a warm resume.
  links.listen(handleUri);
  try {
    handleUri(await getInitialLink());
  } on Object {
    // Deep-link retrieval is best-effort; a failure here must not block
    // app startup.
  }
}

/// No-op on mobile: verifier persistence is only needed for the web redirect
/// flow.
void storeOpenRouterOAuthVerifier(String state, String verifier) {}

/// No-op on mobile: redirect completion is only needed on web.
Future<String?> completeOpenRouterOAuthFromRedirect() async => null;
