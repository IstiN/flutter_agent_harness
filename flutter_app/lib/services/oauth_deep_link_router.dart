// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:collection';

import 'package:fa/services/app_log.dart';

/// Delivers one OAuth deep link to the flow that registered for it.
typedef OAuthDeepLinkHandler = void Function(Uri uri);

/// A route registered on [OAuthDeepLinkRouter].
final class OAuthDeepLinkRoute {
  OAuthDeepLinkRoute({
    required this.flow,
    required this.matches,
    required this.onLink,
  });

  /// The flow id ('openrouter', 'network', …). Re-registering the same
  /// flow replaces its route — registration is idempotent and scoped to
  /// the in-flight attempt.
  final String flow;

  /// Which URIs this flow claims (e.g. `fah://oauth/network` and its
  /// sub-paths for the Android `pathPrefix` filter).
  final bool Function(Uri uri) matches;

  final OAuthDeepLinkHandler onLink;
}

/// The single `fah://oauth/*` router for mobile OAuth deep links
/// (issue #2395): every link the AppLinks subscription delivers is
/// parsed and routed HERE, once — flows never subscribe to the link
/// stream themselves.
///
/// - A link matching a registered route goes to that flow's handler.
/// - A `fah://oauth/*` link that matches no route yet (the flow's
///   receiver has not registered — the cold-start race where the OS
///   delivered the callback before Dart armed the flow) is logged once
///   and buffered, bounded ([bufferLimit], oldest dropped), and replayed
///   exactly once to the first route that claims it on [register].
/// - A `fah://oauth/*` link for an unknown path is logged once (deduped
///   per path) and dropped from routing — it never touches the widget
///   tree.
/// - Anything outside the `fah://oauth/*` route family is ignored
///   silently (other schemes/hosts ride different transports).
///
/// Pure Dart: the link stream and the initial-link read stay behind the
/// platform seam in the boot attachment; the router itself is fully
/// testable on the VM.
final class OAuthDeepLinkRouter {
  OAuthDeepLinkRouter({this.bufferLimit = 8});

  static const _tag = 'oauth_links';

  /// How many unmatched `fah://oauth/*` links may wait for a flow to
  /// register before the oldest is dropped.
  final int bufferLimit;

  final Map<String, OAuthDeepLinkRoute> _routes = {};
  final Queue<Uri> _buffer = Queue<Uri>();
  final Set<String> _loggedUnknownPaths = {};

  /// Registers (or replaces) the route for [route.flow] and replays the
  /// buffered links this route claims — each exactly once.
  void register(OAuthDeepLinkRoute route) {
    _routes[route.flow] = route;
    final replayed = _buffer.where(route.matches).toList();
    _buffer.removeWhere(route.matches);
    for (final uri in replayed) {
      route.onLink(uri);
    }
  }

  /// Removes a flow's route (the in-flight attempt ended). Later links
  /// for it buffer again until the next registration.
  void unregister(String flow) {
    _routes.remove(flow);
  }

  /// Routes one delivered link. Safe for any URI: the platform delivers
  /// engine copies of links (and unrelated schemes) through the same
  /// stream.
  void dispatch(Uri uri) {
    if (uri.scheme != 'fah' || uri.host != 'oauth') return;
    final route = _lookup(uri);
    if (route != null) {
      route.onLink(uri);
      return;
    }
    // Unknown `fah://oauth/*`: log once per path (deduped), buffer
    // bounded for a flow that registers next, never route into the
    // widget tree.
    if (_loggedUnknownPaths.add(uri.path)) {
      AppLog.i(_tag, 'no route for OAuth deep link: $uri');
    }
    _buffer.addLast(uri);
    while (_buffer.length > bufferLimit) {
      _buffer.removeFirst();
    }
  }

  OAuthDeepLinkRoute? _lookup(Uri uri) {
    for (final route in _routes.values) {
      if (route.matches(uri)) return route;
    }
    return null;
  }
}
