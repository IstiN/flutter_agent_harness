// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Deps land via the orchestrator's pubspec change (issue #955).
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:fa/network/auth_deep_link.dart';
import 'package:fa/network/auth_flow.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeepLinkOAuthReceiver', () {
    test('redirectUri is the registered fah://oauth/network callback', () {
      final controller = StreamController<Uri>();
      final receiver = DeepLinkOAuthReceiver.bind(
        links: controller.stream,
        initialLink: null,
      );
      addTearDown(receiver.close);

      expect(receiver.redirectUri.toString(), 'fah://oauth/network');
    });

    test('completes when a matching deep link arrives on the stream', () async {
      final controller = StreamController<Uri>();
      final receiver = DeepLinkOAuthReceiver.bind(
        links: controller.stream,
        initialLink: null,
      );
      addTearDown(receiver.close);

      final pending = receiver.callback;
      controller.add(Uri.parse('fah://oauth/network?code=abc&state=xyz'));
      final callback = await pending;
      expect(callback.queryParameters['code'], 'abc');
      expect(callback.queryParameters['state'], 'xyz');
    });

    test('ignores non-matching links (other hosts/paths/schemes)', () async {
      final controller = StreamController<Uri>();
      final receiver = DeepLinkOAuthReceiver.bind(
        links: controller.stream,
        initialLink: null,
      );
      addTearDown(receiver.close);

      final pending = receiver.callback;
      controller.add(Uri.parse('fah://oauth/openrouter?code=nope'));
      controller.add(Uri.parse('https://example.com/oauth/network?code=nope'));
      controller.add(Uri.parse('fa://oauth/network?code=nope'));
      // The Android intent-filter routes pathPrefix="/network", so a
      // sibling path that merely SHARES the prefix must not match.
      controller.add(Uri.parse('fah://oauth/networking?code=nope'));
      controller.add(Uri.parse('fah://oauth/network?code=abc&state=xyz'));
      final callback = await pending;
      expect(callback.queryParameters['code'], 'abc');
    });

    test(
      'completes for sub-paths (mirrors the Android pathPrefix filter)',
      () async {
        final controller = StreamController<Uri>();
        final receiver = DeepLinkOAuthReceiver.bind(
          links: controller.stream,
          initialLink: null,
        );
        addTearDown(receiver.close);

        final pending = receiver.callback;
        controller.add(
          Uri.parse('fah://oauth/network/extra/segments?code=sub'),
        );
        final callback = await pending;
        expect(callback.queryParameters['code'], 'sub');
      },
    );

    test(
      'completes from the initial link when the flow raced the listener',
      () async {
        final controller = StreamController<Uri>();
        final receiver = DeepLinkOAuthReceiver.bind(
          links: controller.stream,
          initialLink: Uri.parse('fah://oauth/network?code=early&state=s'),
        );
        addTearDown(receiver.close);

        final callback = await receiver.callback;
        expect(callback.queryParameters['code'], 'early');
      },
    );

    test('times out when no deep link arrives', () async {
      final controller = StreamController<Uri>();
      final receiver = DeepLinkOAuthReceiver.bind(
        links: controller.stream,
        initialLink: null,
        timeout: const Duration(milliseconds: 20),
      );
      addTearDown(receiver.close);

      expect(receiver.callback, throwsA(isA<AuthFlowException>()));
    });

    test('close is idempotent and cancels the subscription', () async {
      final controller = StreamController<Uri>();
      final receiver = DeepLinkOAuthReceiver.bind(
        links: controller.stream,
        initialLink: null,
      );
      receiver.close();
      receiver.close();
      expect(controller.hasListener, isFalse);
    });

    test('close cancels the timeout timer (no late unhandled error)', () {
      fakeAsync((async) {
        final controller = StreamController<Uri>();
        final receiver = DeepLinkOAuthReceiver.bind(
          links: controller.stream,
          initialLink: null,
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

  group('DeepLinkOAuthReceiver.bindWithInitialLink', () {
    test('a link delivered while getInitialLink is in flight is not dropped '
        '(warm-resume race)', () async {
      // AppLinks' stream is broadcast-style: an event with no listener
      // attached is DROPPED, and a warm resume reports no initial link
      // at all — so the listener must attach BEFORE the initial link
      // is awaited.
      final controller = StreamController<Uri>.broadcast();
      final initialLink = Completer<Uri?>();
      final receiverFuture = DeepLinkOAuthReceiver.bindWithInitialLink(
        links: controller.stream,
        getInitialLink: () => initialLink.future,
      );

      controller.add(Uri.parse('fah://oauth/network?code=stream&state=s'));
      initialLink.complete(null);

      final receiver = await receiverFuture;
      addTearDown(receiver.close);
      final callback = await receiver.callback;
      expect(callback.queryParameters['code'], 'stream');
    });

    test(
      'dedupes a link arriving on both the stream and the initial link',
      () async {
        final controller = StreamController<Uri>();
        final uri = Uri.parse('fah://oauth/network?code=both&state=s');
        final receiverFuture = DeepLinkOAuthReceiver.bindWithInitialLink(
          links: controller.stream,
          getInitialLink: () async => uri,
        );
        controller.add(uri);

        final receiver = await receiverFuture;
        addTearDown(receiver.close);
        final callback = await receiver.callback;
        expect(callback.queryParameters['code'], 'both');
      },
    );

    test('ignores a non-matching initial link and keeps listening', () async {
      final controller = StreamController<Uri>();
      final receiverFuture = DeepLinkOAuthReceiver.bindWithInitialLink(
        links: controller.stream,
        getInitialLink: () async =>
            Uri.parse('fah://oauth/openrouter?code=nope'),
      );
      final receiver = await receiverFuture;
      addTearDown(receiver.close);

      final pending = receiver.callback;
      controller.add(Uri.parse('fah://oauth/network?code=abc&state=xyz'));
      final callback = await pending;
      expect(callback.queryParameters['code'], 'abc');
    });

    test('a failing getInitialLink does not break the stream path', () async {
      final controller = StreamController<Uri>();
      final receiverFuture = DeepLinkOAuthReceiver.bindWithInitialLink(
        links: controller.stream,
        getInitialLink: () async {
          throw StateError('no initial link');
        },
      );
      final receiver = await receiverFuture;
      addTearDown(receiver.close);

      final pending = receiver.callback;
      controller.add(Uri.parse('fah://oauth/network?code=abc&state=xyz'));
      final callback = await pending;
      expect(callback.queryParameters['code'], 'abc');
    });
  });
}
