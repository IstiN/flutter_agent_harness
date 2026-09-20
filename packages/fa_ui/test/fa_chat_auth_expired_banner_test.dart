// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// A [FakeChatService] with a settable service-level error.
class _ErrorService extends FakeChatService {
  String? err;
  @override
  String? get error => err;
}

const _authExpiredError =
    '302: redirected to the SSO login page. '
    'Re-authorize to refresh the token. '
    '(CLI: /provider codemie sso) [[auth-expired:codemie]]';

Future<void> _pumpScreen(
  WidgetTester tester,
  _ErrorService service, {
  FaAuthRecoveryCallback? onAuthRecovery,
}) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: FaChatScreen(service: service, onAuthRecovery: onAuthRecovery),
    ),
  );
  // flutter_chat_ui's empty chat list schedules a 50ms timer.
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  group('authExpiredDisplayText (issue #692 mapping helper)', () {
    test('strips the marker and the dead CLI hint', () {
      expect(
        authExpiredDisplayText(_authExpiredError),
        '302: redirected to the SSO login page. '
        'Re-authorize to refresh the token.',
      );
    });

    test('leaves a marker-less error untouched', () {
      expect(authExpiredDisplayText('plain failure'), 'plain failure');
    });
  });

  group('FaChatScreen auth-expired error banner (issue #692)', () {
    testWidgets('an auth-expired service error renders the friendly '
        'localized banner, not the raw error', (tester) async {
      final service = _ErrorService()..err = _authExpiredError;
      await _pumpScreen(tester, service);

      expect(find.text('Session expired'), findsOneWidget);
      expect(
        find.text(
          'Your codemie session has expired. Sign in again, then resend '
          'your message.',
        ),
        findsOneWidget,
      );
      // The raw marker and the dead CLI hint never reach the UI.
      expect(find.textContaining('[[auth-expired:'), findsNothing);
      expect(find.textContaining('(CLI:'), findsNothing);
      // The cleaned provider message stays visible (visible errors, #692).
      expect(find.textContaining('302: redirected'), findsOneWidget);
    });

    testWidgets('the banner offers the host re-authorize action', (
      tester,
    ) async {
      String? recovered;
      final service = _ErrorService()..err = _authExpiredError;
      await _pumpScreen(
        tester,
        service,
        onAuthRecovery: (providerId) => recovered = providerId,
      );

      await tester.tap(find.text('Authorize'));
      await tester.pump();

      expect(recovered, 'codemie');
    });

    testWidgets('a plain service error keeps the raw error line', (
      tester,
    ) async {
      final service = _ErrorService()..err = 'boom: network unreachable';
      await _pumpScreen(tester, service);

      expect(find.text('boom: network unreachable'), findsOneWidget);
      expect(find.text('Session expired'), findsNothing);
      expect(find.text('Authorize'), findsNothing);
    });
  });
}
