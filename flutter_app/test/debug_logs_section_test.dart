// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/app_log.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the debug logs row copies AppLog to the clipboard and '
      'confirms with a snackbar', (tester) async {
    AppLog.reset();
    AppLog.i('home', 'listed 0 accessories');
    String? clipboard;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard =
            (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      AppLog.reset();
    });

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DebugLogsSection())),
    );
    await tester.tap(find.byTooltip('Copy debug logs'));
    await tester.pumpAndSettle();

    expect(clipboard, contains('[home] listed 0 accessories'));
    expect(find.text('Debug logs copied to clipboard'), findsOneWidget);
  });
}
