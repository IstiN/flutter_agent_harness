// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Deps land via the orchestrator's pubspec change (issue #955).
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:fa/network/auth_deep_link.dart';
import 'package:fa/network/auth_flow.dart';
import 'package:fa/services/oauth_deep_link_router.dart';
import 'package:fa/services/openrouter_oauth_coordinator.dart';
import 'package:fa/services/openrouter_oauth_links_io.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeepLinkOAuthReceiver', () {
    test('redirectUri is the registered fah://oauth/network callback', () {
      final receiver = DeepLinkOAuthReceiver.bindWithRouter(
        OAuthDeepLinkRouter(),
      );
      addTearDown(receiver.close);

      expect(receiver.redirectUri.toString(), 'fah://oauth/network');
    });

    test(
      'completes when a matching deep link arrives through the router',
      () async {
        final router = OAuthDeepLinkRouter();
        final receiver = DeepLinkOAuthReceiver.bindWithRouter(router);
        addTearDown(receiver.close);

        final pending = receiver.callback;
        router.dispatch(Uri.parse('fah://oauth/network?code=abc&state=xyz'));
        final callback = await pending;
        expect(callback.queryParameters['code'], 'abc');
        expect(callback.queryParameters['state'], 'xyz');
      },
    );

    test('ignores non-matching links (other hosts/paths/schemes)', () async {
      final router = OAuthDeepLinkRouter();
      final receiver = DeepLinkOAuthReceiver.bindWithRouter(router);
      addTearDown(receiver.close);

      final pending = receiver.callback;
      router.dispatch(Uri.parse('fah://oauth/openrouter?code=nope'));
      router.dispatch(Uri.parse('https://example.com/oauth/network?code=nope'));
      router.dispatch(Uri.parse('fa://oauth/network?code=nope'));
      // The Android intent-filter routes pathPrefix="/network", so a
      // sibling path that merely SHARES the prefix must not match.
      router.dispatch(Uri.parse('fah://oauth/networking?code=nope'));
      router.dispatch(Uri.parse('fah://oauth/network?code=abc&state=xyz'));
      final callback = await pending;
      expect(callback.queryParameters['code'], 'abc');
    });

    test(
      'completes for sub-paths (mirrors the Android pathPrefix filter)',
      () async {
        final router = OAuthDeepLinkRouter();
        final receiver = DeepLinkOAuthReceiver.bindWithRouter(router);
        addTearDown(receiver.close);

        final pending = receiver.callback;
        router.dispatch(
          Uri.parse('fah://oauth/network/extra/segments?code=sub'),
        );
        final callback = await pending;
        expect(callback.queryParameters['code'], 'sub');
      },
    );

    test('completes from the buffered cold-start link delivered before '
        'registration (router replay)', () async {
      final router = OAuthDeepLinkRouter();
      // The OS delivered the callback before the flow registered —
      // the router buffers it, and registration replays it.
      router.dispatch(Uri.parse('fah://oauth/network?code=early&state=s'));

      final receiver = DeepLinkOAuthReceiver.bindWithRouter(router);
      addTearDown(receiver.close);

      final callback = await receiver.callback;
      expect(callback.queryParameters['code'], 'early');
    });

    test('times out when no deep link arrives', () async {
      final receiver = DeepLinkOAuthReceiver.bindWithRouter(
        OAuthDeepLinkRouter(),
        timeout: const Duration(milliseconds: 20),
      );
      addTearDown(receiver.close);

      expect(receiver.callback, throwsA(isA<AuthFlowException>()));
    });

    test('close is idempotent and stops delivering links', () async {
      final router = OAuthDeepLinkRouter();
      final receiver = DeepLinkOAuthReceiver.bindWithRouter(router);
      receiver.close();
      receiver.close();

      // Unregistered: a later link must not complete the closed flow.
      router.dispatch(Uri.parse('fah://oauth/network?code=late&state=s'));
      expect(receiver.callback, doesNotComplete);
    });

    test('close cancels the timeout timer (no late unhandled error)', () {
      fakeAsync((async) {
        final receiver = DeepLinkOAuthReceiver.bindWithRouter(
          OAuthDeepLinkRouter(),
          timeout: const Duration(minutes: 3),
        );

        receiver.close();
        // Without the cancel, elapsing past the timeout fires
        // completeError on a future nobody listens to — an unhandled
        // async error that fakeAsync rethrows at the end of the run.
        async.elapse(const Duration(minutes: 5));
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('attachOAuthDeepLinksForLinks (single-subscription boot wiring)', () {
    test('routes an openrouter callback to the coordinator', () async {
      final captureFuture = OpenRouterOAuthCoordinator.instance.capture(
        Uri.parse('https://openrouter.ai/auth?state=s'),
        launchUrl: (_, {required mode}) async => true,
        usesLocalServerCapture: () => false,
      );

      final controller = StreamController<Uri>();
      await attachOAuthDeepLinksForLinks(
        links: controller.stream,
        getInitialLink: () async => null,
        router: OAuthDeepLinkRouter(),
      );
      addTearDown(controller.close);
      addTearDown(OpenRouterOAuthCoordinator.instance.reset);

      controller.add(Uri.parse('fah://oauth/openrouter?code=deep&state=s'));
      expect(await captureFuture, 'deep');
    });

    test('a link delivered while getInitialLink is in flight is not dropped '
        '(warm-resume race)', () async {
      // AppLinks' stream is broadcast-style: an event with no listener
      // attached is DROPPED, and a warm resume reports no initial link
      // at all — so the router's subscription must attach BEFORE the
      // initial link is awaited.
      final router = OAuthDeepLinkRouter();
      final controller = StreamController<Uri>.broadcast();
      final initialLink = Completer<Uri?>();
      final attached = attachOAuthDeepLinksForLinks(
        links: controller.stream,
        getInitialLink: () => initialLink.future,
        router: router,
      );

      controller.add(Uri.parse('fah://oauth/network?code=stream&state=s'));
      initialLink.complete(null);
      await attached;

      // The flow registers after the dust settles and still gets the link
      // (buffered replay — the cold-start race window).
      final receiver = DeepLinkOAuthReceiver.bindWithRouter(router);
      addTearDown(receiver.close);
      final callback = await receiver.callback;
      expect(callback.queryParameters['code'], 'stream');
    });

    test(
      'dedupes a link arriving on both the stream and the initial link',
      () async {
        final router = OAuthDeepLinkRouter();
        final controller = StreamController<Uri>();
        final uri = Uri.parse('fah://oauth/network?code=both&state=s');
        await attachOAuthDeepLinksForLinks(
          links: controller.stream,
          getInitialLink: () async => uri,
          router: router,
        );
        addTearDown(controller.close);
        controller.add(uri);

        final receiver = DeepLinkOAuthReceiver.bindWithRouter(router);
        addTearDown(receiver.close);
        final callback = await receiver.callback;
        expect(callback.queryParameters['code'], 'both');
      },
    );

    test('a failing getInitialLink does not break the stream path', () async {
      final router = OAuthDeepLinkRouter();
      final controller = StreamController<Uri>();
      await attachOAuthDeepLinksForLinks(
        links: controller.stream,
        getInitialLink: () async {
          throw StateError('no initial link');
        },
        router: router,
      );
      addTearDown(controller.close);

      final receiver = DeepLinkOAuthReceiver.bindWithRouter(router);
      addTearDown(receiver.close);
      final pending = receiver.callback;
      controller.add(Uri.parse('fah://oauth/network?code=abc&state=xyz'));
      final callback = await pending;
      expect(callback.queryParameters['code'], 'abc');
    });
  });

  group('exactly one AppLinks construction (issue #2395 guard)', () {
    test(
      'AppLinks() is constructed only in the boot attachment file',
      () async {
        // Word-boundary match: `resolveAppLinks(` must not count — the
        // guard pins the app_links PLUGIN construction sites only.
        final pattern = RegExp(r'\bAppLinks\(');
        final sites = <String>[];
        final lib = Directory('lib');
        await for (final entity in lib.list(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          if (pattern.hasMatch(entity.readAsStringSync())) {
            sites.add(entity.path);
          }
        }
        expect(sites, ['lib/services/openrouter_oauth_links_io.dart']);
      },
    );
  });
}
