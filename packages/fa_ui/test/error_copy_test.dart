// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// Issue #869: every error surface carries the copy affordance — tap puts
/// the FULL error text on the clipboard and flips the icon to a check;
/// long-press copies the diagnostics envelope; a clipboard refusal shows a
/// brief failed state instead of crashing.

String? _clipboardText;
Object? _clipboardFailure;

void _mockClipboard() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          if (_clipboardFailure != null) throw _clipboardFailure!;
          _clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
}

/// Lets the async copy settle, then flushes the 1.5s revert timer so no
/// timer is left pending at test end.
Future<void> _settleCopy(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1600));
  await tester.pump();
}

void main() {
  setUp(_mockClipboard);
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    _clipboardText = null;
    _clipboardFailure = null;
  });

  group('buildErrorCopyEnvelope (second tier)', () {
    test('no diagnostics = message verbatim', () {
      const message = 'SessionException: renamePath not supported';
      expect(buildErrorCopyEnvelope(message: message), message);
      expect(
        buildErrorCopyEnvelope(
          message: message,
          diagnostics: const ErrorCopyDiagnostics(),
        ),
        message,
      );
    });

    test('full diagnostics appends session, version, platform lines', () {
      expect(
        buildErrorCopyEnvelope(
          message: 'boom',
          diagnostics: const ErrorCopyDiagnostics(
            sessionId: 'abc123',
            appVersion: '1.0.466',
            platform: 'macos',
          ),
        ),
        'boom\n\n--- diagnostics ---\n'
        'session: abc123\nversion: 1.0.466\nplatform: macos',
      );
    });

    test('partial diagnostics omit absent lines', () {
      expect(
        buildErrorCopyEnvelope(
          message: 'boom',
          diagnostics: const ErrorCopyDiagnostics(sessionId: 'abc123'),
        ),
        'boom\n\n--- diagnostics ---\nsession: abc123',
      );
    });
  });

  group('error snackbar copy affordance (AC1)', () {
    const message =
        'SessionException: renamePath not supported: '
        '/Users/x/.fah/sessions/very-long-id.jsonl';

    Future<void> pumpSnackHost(WidgetTester tester, String message) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showFahErrorSnack(context, message),
                    child: const Text('fail'),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('fail'));
      // One zero-duration frame starts the snackbar entrance; the timed
      // pump then lands the ~600ms slide-in so the icon is hit-testable.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
    }

    /// Ends a snack test with no pending snackbar timers (dismiss + exit).
    Future<void> _flushSnacks(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('tap writes the exact rendered message and flips to check', (
      tester,
    ) async {
      await pumpSnackHost(tester, message);
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.copy_rounded));
      await tester.pump();
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(_clipboardText, message);

      await _settleCopy(tester);
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
      await _flushSnacks(tester);
    });

    testWidgets('very long error copies FULL text (E1)', (tester) async {
      final long = 'SessionException: path bomb: ${'a/' * 1500}file.jsonl';
      // The 3KB error wraps into a very tall snack — give it room.
      tester.view.physicalSize = const Size(800, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpSnackHost(tester, long);

      await tester.tap(find.byIcon(Icons.copy_rounded));
      await _settleCopy(tester);
      expect(_clipboardText, long);
      expect(_clipboardText!.length, greaterThan(3000));
      await _flushSnacks(tester);
    });

    testWidgets('clipboard refusal shows the failed state, no crash (E2)', (
      tester,
    ) async {
      _clipboardFailure = PlatformException(code: 'unavailable');
      await pumpSnackHost(tester, message);

      await tester.tap(find.byIcon(Icons.copy_rounded));
      await tester.pump();
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);

      await _settleCopy(tester);
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _flushSnacks(tester);
    });

    testWidgets('stacked errors each copy their own text (E3)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () {
                      showFahErrorSnack(
                        context,
                        'first failure',
                        duration: const Duration(seconds: 1),
                      );
                      showFahErrorSnack(
                        context,
                        'second failure',
                        duration: const Duration(seconds: 4),
                      );
                    },
                    child: const Text('fail'),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('fail'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      await tester.tap(find.byIcon(Icons.copy_rounded));
      await tester.pump();
      expect(_clipboardText, 'first failure');
      await _settleCopy(tester);

      // First snack's 1s duration elapses → the queued one shows; let its
      // slide-in land before tapping.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('second failure'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.copy_rounded));
      await tester.pump();
      expect(_clipboardText, 'second failure');
      await _settleCopy(tester);
      await _flushSnacks(tester);
    });
  });

  group('chat error bubble copy affordance (AC2)', () {
    Future<void> pumpErrorBanner(WidgetTester tester, String error) async {
      final service = _ErrorService()..err = error;
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: FaChatScreen(service: service)),
      );
      // flutter_chat_ui's empty chat list schedules a 50ms timer.
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('provider error banner copies the full error verbatim', (
      tester,
    ) async {
      const error =
          '429: rate limited by provider — retry after 30s '
          '(request id: req_luna_0429)';
      await pumpErrorBanner(tester, error);

      await tester.tap(find.byIcon(Icons.copy_rounded));
      await tester.pump();
      expect(_clipboardText, error);
      await _settleCopy(tester);
    });

    testWidgets('auth-expired banner copies the RAW error, not the '
        'friendly text', (tester) async {
      const error =
          '302: redirected to the SSO login page. Re-authorize to refresh '
          'the token. (CLI: /provider codemie sso) [[auth-expired:codemie]]';
      await pumpErrorBanner(tester, error);

      expect(find.text('Session expired'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.copy_rounded));
      await tester.pump();
      expect(_clipboardText, error);
      await _settleCopy(tester);
    });
  });
}

/// A [FakeChatService] with a settable service-level error.
class _ErrorService extends FakeChatService {
  String? err;
  @override
  String? get error => err;
}
