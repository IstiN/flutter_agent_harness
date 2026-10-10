// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/network/auth_deep_link.dart';
import 'package:fa/network/auth_flow.dart';
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
      controller.add(Uri.parse('fah://oauth/network?code=abc&state=xyz'));
      final callback = await pending;
      expect(callback.queryParameters['code'], 'abc');
    });

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
  });
}
