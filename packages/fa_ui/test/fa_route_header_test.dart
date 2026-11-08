// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _headerPage(BuildContext context) => Scaffold(
  appBar: faRouteAppBar(
    context: context,
    title: const Text('Edit Transcription'),
    leading: const BackButton(),
  ),
  body: const SizedBox.expand(),
);

Future<void> _pumpHeader(WidgetTester tester, {bool inDialog = false}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: inDialog
          ? FaDialogScope(child: Builder(builder: _headerPage))
          : Builder(builder: _headerPage),
    ),
  );
}

void main() {
  testWidgets('macOS lowers only Back/navigation below the titlebar', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _pumpHeader(tester);

      final header = find.byType(FaRouteHeader);
      expect(header, findsOneWidget);
      expect(tester.getSize(header).height, 32 + kToolbarHeight);
      final title = tester.getRect(find.text('Edit Transcription'));
      final back = tester.getRect(find.byType(BackButton));
      expect(title.center.dy, lessThan(FaWindowChrome.titlebarHeight));
      expect(back.top, greaterThanOrEqualTo(FaWindowChrome.titlebarHeight));
      expect(
        back.left,
        lessThan(FaWindowChrome.compactLeadingInset),
        reason: 'Back moves below the lights, not behind or beside them',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('centered dialogs and phones keep the ordinary AppBar', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await _pumpHeader(tester, inDialog: true);
      expect(find.byType(FaRouteHeader), findsNothing);
      expect(tester.getSize(find.byType(AppBar)).height, kToolbarHeight);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await _pumpHeader(tester);
      expect(find.byType(FaRouteHeader), findsNothing);
      expect(tester.getSize(find.byType(AppBar)).height, kToolbarHeight);
      final title = tester.getRect(find.text('Edit Transcription'));
      final back = tester.getRect(find.byType(BackButton));
      expect((title.center.dy - back.center.dy).abs(), lessThan(1));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
