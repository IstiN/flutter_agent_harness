// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/auth_flow.dart';
import 'package:fa/network/auth_loopback_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LoopbackOAuthReceiver', () {
    test('close cancels the timeout timer (no late unhandled error)', () async {
      final receiver = await LoopbackOAuthReceiver.bind(
        timeout: const Duration(milliseconds: 50),
      );
      receiver.close();

      // If close() left the timer running, it fires about now and calls
      // completeError on a future nobody listens to — an unhandled async
      // error that fails the test zone.
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
  });

  group(
    'WebAuthSessionOAuthReceiver (iOS unified ASWebAuthenticationSession)',
    () {
      test(
        'iOS binds WebAuthSessionOAuthReceiver and openAuthUrlImpl presents it',
        () async {
          Uri? presentedUrl;
          String? presentedScheme;
          var cancelled = false;
          final receiver = await startOAuthCallbackReceiverForPlatform(
            isIOS: true,
            isAndroid: false,
            iosAuthenticate: (authUrl, scheme) async {
              presentedUrl = authUrl;
              presentedScheme = scheme;
              return 'fah://oauth/network?code=ios-code&state=st-42';
            },
            iosCancel: () async {
              cancelled = true;
            },
          );
          addTearDown(receiver.close);

          expect(receiver, isA<WebAuthSessionOAuthReceiver>());
          expect(receiver.redirectUri.toString(), 'fah://oauth/network');

          final authUrl = Uri.parse(
            'https://accounts.google.com/o/oauth2/auth?state=st-42',
          );
          await openAuthUrlImpl(authUrl);
          final callback = await receiver.callback;

          expect(presentedUrl, authUrl);
          expect(presentedScheme, 'fah');
          expect(callback.queryParameters['code'], 'ios-code');
          expect(callback.queryParameters['state'], 'st-42');

          receiver.close();
          expect(cancelled, isTrue);
        },
      );

      test('user cancel surfaces AuthFlowException', () async {
        final receiver = await startOAuthCallbackReceiverForPlatform(
          isIOS: true,
          isAndroid: false,
          iosAuthenticate: (_, _) async => null,
          iosCancel: () async {},
        );
        addTearDown(receiver.close);

        await openAuthUrlImpl(Uri.parse('https://example.com/auth'));
        await expectLater(
          receiver.callback,
          throwsA(
            isA<AuthFlowException>().having(
              (e) => e.message,
              'message',
              contains('cancelled'),
            ),
          ),
        );
      });

      test('PlatformException surfaces AuthFlowException', () async {
        final receiver = await startOAuthCallbackReceiverForPlatform(
          isIOS: true,
          isAndroid: false,
          iosAuthenticate: (_, _) async => throw PlatformException(
            code: 'auth_session_unavailable',
            message: 'ASWebAuthenticationSession could not start',
          ),
          iosCancel: () async {},
        );
        addTearDown(receiver.close);

        await openAuthUrlImpl(Uri.parse('https://example.com/auth'));
        await expectLater(
          receiver.callback,
          throwsA(
            isA<AuthFlowException>().having(
              (e) => e.message,
              'message',
              contains('ASWebAuthenticationSession'),
            ),
          ),
        );
      });

      test('unexpected callback URI surfaces AuthFlowException', () async {
        final receiver = await startOAuthCallbackReceiverForPlatform(
          isIOS: true,
          isAndroid: false,
          iosAuthenticate: (_, _) async => 'fah://oauth/openrouter?code=wrong',
          iosCancel: () async {},
        );
        addTearDown(receiver.close);

        await openAuthUrlImpl(Uri.parse('https://example.com/auth'));
        await expectLater(
          receiver.callback,
          throwsA(
            isA<AuthFlowException>().having(
              (e) => e.message,
              'message',
              contains('unexpected callback'),
            ),
          ),
        );
      });
    },
  );
}
