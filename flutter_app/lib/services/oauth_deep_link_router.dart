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

/// A `fah://oauth/*` link that matched no route when it was delivered.
/// [receivedAt] bounds its replay life: a callback older than the flow
/// timeout can never be exchanged (every possible receiving flow has
/// already timed out), so it must not poison a later flow with a state
/// mismatch.
final class _BufferedLink {
  _BufferedLink(this.uri, this.receivedAt);
  final Uri uri;
  final DateTime receivedAt;
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
///   and buffered: bounded ([bufferLimit], oldest dropped) and
///   time-bounded ([replayTtl] — a stale callback is never replayed
///   into a later flow), and replayed exactly once to the first route
///   that claims it on [register].
/// - A `fah://oauth/*` link for an unknown path is logged once (deduped
///   per path, the log line carries scheme/host/path only — never the
///   credential query) and dropped from routing — it never touches the
///   widget tree.
/// - Anything outside the `fah://oauth/*` route family is ignored
///   silently (other schemes/hosts ride different transports).
///
/// Pure Dart: the link stream and the initial-link read stay behind the
/// platform seam in the boot attachment; the router itself is fully
/// testable on the VM.
final class OAuthDeepLinkRouter {
  OAuthDeepLinkRouter({
    this.bufferLimit = 8,
    this.replayTtl = const Duration(minutes: 3),
    DateTime Function()? clock,
    void Function(String message)? onUnknown,
  }) : _clock = clock ?? DateTime.now,
       _onUnknown = onUnknown ?? _defaultUnknownLog;

  final DateTime Function() _clock;
  final void Function(String message) _onUnknown;

  /// How many unmatched `fah://oauth/*` links may wait for a flow to
  /// register before the oldest is dropped.
  final int bufferLimit;

  /// How long a buffered callback stays eligible for replay — the same
  /// envelope as the OAuth flow timeout (a flow cannot live longer, so
  /// an older callback has no legitimate receiver).
  final Duration replayTtl;

  final Map<String, OAuthDeepLinkRoute> _routes = {};
  final Queue<_BufferedLink> _buffer = Queue<_BufferedLink>();

  /// Distinct unknown paths already logged (bounded — recent-first
  /// rotation), so a repeated delivery logs once, not per attempt.
  final Set<String> _loggedUnknownPaths = {};
  static const _loggedUnknownPathsCap = 64;

  /// Registers (or replaces) the route for [route.flow] and replays the
  /// still-fresh buffered links this route claims — each exactly once.
  void register(OAuthDeepLinkRoute route) {
    _routes[route.flow] = route;
    final replayed = _buffer
        .where((link) => _isFresh(link) && route.matches(link.uri))
        .toList();
    _buffer.removeWhere((link) => _isFresh(link) && route.matches(link.uri));
    for (final link in replayed) {
      route.onLink(link.uri);
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
    // Unknown `fah://oauth/*`: log once per path (deduped, redacted —
    // no credential query), buffer bounded + time-bounded for a flow
    // that registers next, never route into the widget tree.
    if (_loggedUnknownPaths.add(uri.path)) {
      if (_loggedUnknownPaths.length > _loggedUnknownPathsCap) {
        _loggedUnknownPaths.remove(_loggedUnknownPaths.first);
      }
      _onUnknown(
        'no route for OAuth deep link: ${uri.scheme}://${uri.host}${uri.path}',
      );
    }
    while (_buffer.isNotEmpty && !_isFresh(_buffer.first)) {
      _buffer.removeFirst();
    }
    _buffer.addLast(_BufferedLink(uri, _clock()));
    while (_buffer.length > bufferLimit) {
      _buffer.removeFirst();
    }
  }

  bool _isFresh(_BufferedLink link) =>
      _clock().difference(link.receivedAt) <= replayTtl;

  OAuthDeepLinkRoute? _lookup(Uri uri) {
    for (final route in _routes.values) {
      if (route.matches(uri)) return route;
    }
    return null;
  }
}

// Keep the default log sink next to the router so the redaction contract
// has exactly one production call site.
void _defaultUnknownLog(String message) => AppLog.i('oauth_links', message);
