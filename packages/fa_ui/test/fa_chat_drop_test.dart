// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.
//
// OS drag-and-drop onto the chat surface (issue #465, AC3 + edge cases):
// the tests drive the REAL desktop_drop pipeline by firing the plugin's
// platform channel (`desktop_drop`) the way the native side does —
// entered/updated/exited carry a location, `performOperation*` carries the
// dropped item payloads. Linux test hosts skip hover-point scaling, so
// logical widget-test coordinates go through untouched.

import 'dart:io';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

const _channel = MethodChannel('desktop_drop');

/// Fires a platform→dart method call on the desktop_drop channel. The
/// dispatch rides [tester.runAsync] because the drop handler chain stages
/// files through real IO — fake-async futures would never complete (the
/// chat_composer_test paste-settle pattern). Pass [until] to hold the
/// real-async window open until the drop's observable result lands:
/// batch reads and oversized files blow past any fixed delay, and a
/// future still mid-read when the window closes would hang the
/// fake-async drain.
Future<void> _fireChannel(
  WidgetTester tester,
  String method,
  Object arguments, {
  bool Function()? until,
}) async {
  final data = const StandardMethodCodec().encodeMethodCall(
    MethodCall(method, arguments),
  );
  await tester.runAsync(() async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _channel.name,
      data,
      (_) {},
    );
    if (until != null) {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!until() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  });
  await tester.pump();
}

Future<FakeChatService> _pumpScreen(WidgetTester tester) async {
  final service = FakeChatService();
  await tester.pumpWidget(
    MaterialApp(home: FaChatScreen(service: service, showAppBar: false)),
  );
  // flutter_chat_ui's empty chat list schedules a 50ms timer.
  await tester.pump(const Duration(seconds: 1));
  return service;
}

/// A real temp file (DropItem.readAsBytes hits the actual filesystem).
/// Synchronous IO: the test body's fake-async zone never advances real
/// async file futures.
File _tempFile(String name, [List<int> bytes = const [1, 2, 3]]) {
  final dir = Directory.systemTemp.createTempSync('fa465');
  final file = File('${dir.path}/$name');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  file.writeAsBytesSync(bytes);
  return file;
}

void main() {
  testWidgets('AC3: a 2-file drop over the chat area stages 2 chips with '
      'the drop highlight while dragging', (tester) async {
    final service = await _pumpScreen(tester);
    final files = [
      _tempFile('shot.png'),
      _tempFile('notes.txt', 'hello'.codeUnits),
    ];

    // Hover inside the chat body: the highlight must show during the drag.
    await _fireChannel(tester, 'entered', <double>[400, 300]);
    expect(find.byKey(const ValueKey('faChatDropHighlight')), findsOneWidget);

    await _fireChannel(
      tester,
      'performOperation',
      [for (final f in files) f.path],
      until: () => service.stagedCalls.length == 2,
    );

    // Highlight gone, both files staged through the same path as the
    // picker, both chips rendered.
    expect(find.byKey(const ValueKey('faChatDropHighlight')), findsNothing);
    expect(service.stagedCalls.map((c) => c.name), ['shot.png', 'notes.txt']);
    expect(find.byIcon(Icons.close), findsNWidgets(2));
    expect(find.textContaining('notes.txt'), findsOneWidget);
  });

  testWidgets('AC3: a text drop inserts text into the composer instead of '
      'staging anything', (tester) async {
    final service = await _pumpScreen(tester);

    // Linux delivers text drags as rawText with no resolvable file paths.
    await _fireChannel(
      tester,
      'performOperation_linux',
      <Object>['dragged note', <double>[400, 300]],
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'dragged note');
    expect(service.stagedCalls, isEmpty);
  });

  testWidgets('E4: a dropped directory is rejected with a hint, sibling '
      'files still stage', (tester) async {
    final service = await _pumpScreen(tester);
    final file = _tempFile('real.txt', 'x'.codeUnits);

    await _fireChannel(
      tester,
      'performOperation',
      ['/tmp', file.path],
      until: () => service.stagedCalls.isNotEmpty,
    );

    expect(find.textContaining('Folders cannot be attached'), findsOneWidget);
    expect(service.stagedCalls.map((c) => c.name), ['real.txt']);
  });

  testWidgets('E2: paste spam beyond the attachment cap stages the cap and '
      'notices the skipped count', (tester) async {
    final service = await _pumpScreen(tester);
    final files = [
      for (var i = 0; i < 12; i++) _tempFile('spam-$i.txt'),
    ];

    await _fireChannel(
      tester,
      'performOperation',
      [for (final f in files) f.path],
      until: () => service.stagedCalls.length == 10,
    );

    expect(service.stagedCalls, hasLength(10));
    expect(find.textContaining('skipped 2'), findsOneWidget);
  });

  testWidgets('E1: an oversized dropped file surfaces the size-cap reason '
      'and stages nothing', (tester) async {
    final service = await _pumpScreen(tester);
    final file = _tempFile('huge.bin', Uint8List(25 * 1024 * 1024 + 1));

    await _fireChannel(
      tester,
      'performOperation',
      [file.path],
      until: () => find.textContaining('exceeds the').evaluate().isNotEmpty,
    );

    expect(find.textContaining('exceeds the'), findsOneWidget);
    expect(service.stagedCalls, isEmpty);
  });
}
