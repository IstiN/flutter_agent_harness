// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/oauth_deep_link_router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OAuthDeepLinkRouter', () {
    test('routes the openrouter callback (exact path) to its flow', () {
      final router = OAuthDeepLinkRouter();
      final codes = <String>[];
      router.register(
        OAuthDeepLinkRoute(
          flow: 'openrouter',
          matches: (uri) =>
              uri.scheme == 'fah' &&
              uri.host == 'oauth' &&
              uri.path == '/openrouter',
          onLink: (uri) => codes.add(uri.queryParameters['code']!),
        ),
      );

      router.dispatch(Uri.parse('fah://oauth/openrouter?code=or-1'));
      expect(codes, ['or-1']);
    });

    test('routes the network callback and its sub-paths to its flow', () {
      final router = OAuthDeepLinkRouter();
      final codes = <String>[];
      router.register(
        OAuthDeepLinkRoute(
          flow: 'network',
          matches: (uri) =>
              uri.scheme == 'fah' &&
              uri.host == 'oauth' &&
              (uri.path == '/network' || uri.path.startsWith('/network/')),
          onLink: (uri) => codes.add(uri.queryParameters['code']!),
        ),
      );

      router.dispatch(Uri.parse('fah://oauth/network?code=n-1'));
      router.dispatch(Uri.parse('fah://oauth/network/extra?code=n-2'));
      expect(codes, ['n-1', 'n-2']);
    });

    test('multi-provider flows each see only their own links', () {
      final router = OAuthDeepLinkRouter();
      final openrouter = <String>[];
      final network = <String>[];
      router.register(
        OAuthDeepLinkRoute(
          flow: 'openrouter',
          matches: (uri) => uri.path == '/openrouter',
          onLink: (uri) => openrouter.add(uri.queryParameters['code']!),
        ),
      );
      router.register(
        OAuthDeepLinkRoute(
          flow: 'network',
          matches: (uri) => uri.path.startsWith('/network'),
          onLink: (uri) => network.add(uri.queryParameters['code']!),
        ),
      );

      router.dispatch(Uri.parse('fah://oauth/openrouter?code=or'));
      router.dispatch(Uri.parse('fah://oauth/network?code=nw'));
      expect(openrouter, ['or']);
      expect(network, ['nw']);
    });

    test(
      'drops an unknown fah://oauth/* path: logged once, no route called',
      () {
        final router = OAuthDeepLinkRouter();
        final delivered = <Uri>[];
        router.register(
          OAuthDeepLinkRoute(
            flow: 'openrouter',
            matches: (uri) => uri.path == '/openrouter',
            onLink: delivered.add,
          ),
        );

        router.dispatch(Uri.parse('fah://oauth/github?code=x'));
        router.dispatch(Uri.parse('fah://oauth/github?code=y'));
        expect(delivered, isEmpty);
      },
    );

    test('ignores links outside the fah://oauth/* route family', () {
      final router = OAuthDeepLinkRouter();
      final delivered = <Uri>[];
      router.register(
        OAuthDeepLinkRoute(
          flow: 'openrouter',
          matches: (uri) => uri.path == '/openrouter',
          onLink: delivered.add,
        ),
      );

      router.dispatch(Uri.parse('https://example.com/oauth/openrouter?code=x'));
      router.dispatch(Uri.parse('fah://settings/theme?x=1'));
      expect(delivered, isEmpty);
    });

    test(
      'buffers a link delivered before its flow registers, replays once',
      () {
        final router = OAuthDeepLinkRouter();
        // Cold start: the callback lands before any flow registered.
        router.dispatch(Uri.parse('fah://oauth/network?code=cold&state=s'));

        final received = <Uri>[];
        router.register(
          OAuthDeepLinkRoute(
            flow: 'network',
            matches: (uri) => uri.path.startsWith('/network'),
            onLink: received.add,
          ),
        );
        expect(received.single.queryParameters['code'], 'cold');

        // Replayed exactly once: a second registration gets nothing.
        final second = <Uri>[];
        router.register(
          OAuthDeepLinkRoute(
            flow: 'network',
            matches: (uri) => uri.path.startsWith('/network'),
            onLink: second.add,
          ),
        );
        expect(second, isEmpty);
      },
    );

    test('does not replay a stale buffered callback into a later flow', () {
      // A buffered callback older than the flow-timeout envelope can
      // never be exchanged (the receiving flow's own 3-minute timeout has
      // long passed): replaying it would fail an unrelated later flow
      // with a state mismatch.
      var now = DateTime(2026, 11, 25, 12);
      final router = OAuthDeepLinkRouter(
        clock: () => now,
        replayTtl: const Duration(minutes: 3),
      );

      router.dispatch(Uri.parse('fah://oauth/network?code=stale&state=s'));
      now = now.add(const Duration(minutes: 4));

      final received = <Uri>[];
      router.register(
        OAuthDeepLinkRoute(
          flow: 'network',
          matches: (uri) => uri.path.startsWith('/network'),
          onLink: received.add,
        ),
      );
      expect(received, isEmpty);
    });

    test(
      'replays a buffered callback that is still fresh (within the TTL)',
      () {
        var now = DateTime(2026, 11, 25, 12);
        final router = OAuthDeepLinkRouter(clock: () => now);

        router.dispatch(Uri.parse('fah://oauth/network?code=fresh&state=s'));
        now = now.add(const Duration(minutes: 1));

        final received = <Uri>[];
        router.register(
          OAuthDeepLinkRoute(
            flow: 'network',
            matches: (uri) => uri.path.startsWith('/network'),
            onLink: received.add,
          ),
        );
        expect(received.single.queryParameters['code'], 'fresh');
      },
    );

    test('the unknown-route log never carries credentials', () {
      final lines = <String>[];
      final router = OAuthDeepLinkRouter(onUnknown: lines.add);

      router.dispatch(
        Uri.parse('fah://oauth/github?code=SECRET-CODE&state=SECRET-STATE'),
      );
      expect(lines, hasLength(1));
      expect(lines.single.contains('SECRET'), isFalse);
      expect(lines.single, contains('/github'));
    });

    test('the unknown-path dedup set stays bounded and still dedupes', () {
      final lines = <String>[];
      final router = OAuthDeepLinkRouter(onUnknown: lines.add);
      for (var i = 0; i < 100; i++) {
        router.dispatch(Uri.parse('fah://oauth/path$i?code=x'));
      }
      expect(lines, hasLength(100));

      // The cap rotates old entries, but the most recent path is still
      // deduped after the rotation.
      router.dispatch(Uri.parse('fah://oauth/path99?code=x'));
      expect(lines, hasLength(100));
    });

    test('the buffer is bounded: the oldest unmatched link is dropped', () {
      final router = OAuthDeepLinkRouter(bufferLimit: 2);
      for (final path in ['/network?code=1', '/network?code=2']) {
        router.dispatch(Uri.parse('fah://oauth$path'));
      }
      router.dispatch(Uri.parse('fah://oauth/network?code=3'));

      final received = <String>[];
      router.register(
        OAuthDeepLinkRoute(
          flow: 'network',
          matches: (uri) => uri.path.startsWith('/network'),
          onLink: (uri) => received.add(uri.queryParameters['code']!),
        ),
      );
      expect(received, ['2', '3']);
    });

    test('re-registering a flow replaces its handler (idempotent)', () {
      final router = OAuthDeepLinkRouter();
      final first = <Uri>[];
      final second = <Uri>[];
      OAuthDeepLinkRoute routeOf(void Function(Uri) onLink) =>
          OAuthDeepLinkRoute(
            flow: 'network',
            matches: (uri) => uri.path.startsWith('/network'),
            onLink: onLink,
          );
      router.register(routeOf(first.add));
      router.register(routeOf(second.add));

      router.dispatch(Uri.parse('fah://oauth/network?code=one'));
      expect(first, isEmpty);
      expect(second.map((u) => u.queryParameters['code']), ['one']);
    });

    test('unregister returns the flow to buffering', () {
      final router = OAuthDeepLinkRouter();
      final received = <Uri>[];
      final route = OAuthDeepLinkRoute(
        flow: 'network',
        matches: (uri) => uri.path.startsWith('/network'),
        onLink: received.add,
      );
      router.register(route);
      router.unregister('network');

      router.dispatch(Uri.parse('fah://oauth/network?code=after'));
      expect(received, isEmpty);

      router.register(route);
      expect(received.single.queryParameters['code'], 'after');
    });
  });
}
