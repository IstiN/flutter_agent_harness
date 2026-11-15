// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// Issue #869: every error snackbar carries the one-tap copy affordance.
/// The motivating surface (sidebar delete failure — the owner screenshotted
/// a path-laden SessionException to hand it to an agent) over a realistic
/// session-list frame: idle state with the copy icon, and the tapped state
/// with the confirmation check.
void main() {
  setUpAll(ensureGoldenFonts);

  String? clipboardText;
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    clipboardText = null;
  });

  const message =
      'SessionException: renamePath not supported, '
      'father = /Users/agent/.fah/sessions, '
      'path = /Users/agent/.fah/sessions/'
      'a1b2c3d4-e5f6-47a8-9b0c-1d2e3f4a5b6c.jsonl';

  // The theme's family-less snackbar contentTextStyle falls back to the
  // system font (fine at runtime, placeholder boxes in golden hosts) —
  // pin the bundled Inter for snapshots.
  final base = buildFahTheme();
  final snackTheme = base.copyWith(
    snackBarTheme: base.snackBarTheme.copyWith(
      contentTextStyle:
          (base.snackBarTheme.contentTextStyle ?? const TextStyle()).copyWith(
            fontFamily: 'Inter',
          ),
    ),
  );

  Future<void> pumpSnackFrame(WidgetTester tester) async {
    await pumpGolden(
      tester,
      Scaffold(
        appBar: AppBar(title: const Text('Fa — Sessions')),
        body: Builder(
          builder: (context) {
            final theme = Theme.of(context);
            return ListView(
              children: [
                for (final (title, time, live) in const [
                  ('Refactor golden guard', '2m ago', true),
                  ('Fix l10n key drift', '18m ago', false),
                  ('Trajectory export polish', '1h ago', false),
                  ('Sandbox shell jobs', '3h ago', false),
                  ('Compaction budget tuning', 'yesterday', false),
                ])
                  ListTile(
                    leading: Icon(
                      live
                          ? Icons.fiber_manual_record
                          : Icons.chat_bubble_outline,
                      size: 14,
                      color: live ? const Color(0xFF3FB950) : null,
                    ),
                    title: Text(title),
                    subtitle: Text(
                      '$title session · ~/work/flutter_agent_harness',
                    ),
                    trailing: Text(time, style: theme.textTheme.bodySmall),
                  ),
              ],
            );
          },
        ),
      ),
      size: goldenSizePhone,
      theme: snackTheme,
      wrap: (child) => child,
    );

    final context = tester.element(find.byType(ListView));
    showFahErrorSnack(context, message, sessionId: 'a1b2c3d4-e5f6');
    // Zero-duration frame starts the entrance; the timed pump lands it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  }

  /// Ends a snack scene with no pending snackbar timers (dismiss + exit).
  Future<void> flushSnacks(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('error snackbar shows the copy affordance (idle)', (
    tester,
  ) async {
    await pumpSnackFrame(tester);
    await expectGolden(tester, 'error_copy_snackbar_idle_phone');
    await flushSnacks(tester);
  });

  testWidgets('tapping copy flips the affordance to a check (AC1)', (
    tester,
  ) async {
    await pumpSnackFrame(tester);
    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();
    expect(clipboardText, contains('renamePath not supported'));
    await expectGolden(tester, 'error_copy_snackbar_tapped_phone');
    await tester.pump(const Duration(milliseconds: 1600));
    await flushSnacks(tester);
  });
}
