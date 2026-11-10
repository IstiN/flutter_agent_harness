// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io' show Platform;

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

const _duoGeometry = FaDuoGeometry(
  isDuo: true,
  hardwareModel: 'iPhone19,4',
  verticalBarEdge: FaDuoVerticalBarEdge.trailing,
  safeAreaInsets: EdgeInsets.only(top: 59, right: 84),
  occlusions: [Rect.fromLTWH(306, 12, 84, 114)],
  divisions: [],
);

Widget _automaticHeaderPage(BuildContext context) => Scaffold(
  appBar: faRouteAppBar(context: context, title: const Text('Edit provider')),
  body: SafeArea(
    child: TextButton(
      key: const ValueKey('providerRouteBody'),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            appBar: faRouteAppBar(
              context: context,
              title: const Text('Choose model'),
            ),
            body: const SizedBox.expand(),
          ),
        ),
      ),
      child: const Text('Next'),
    ),
  ),
);

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

  testWidgets('Duo pushed route puts automatic Back in the native rail', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 59, right: 84);
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        FaDuoLayoutScope(
          geometry: _duoGeometry,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: _automaticHeaderPage)),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final back = find.byType(BackButton);
      expect(back, findsOneWidget);
      final rect = tester.getRect(back);
      expect(rect.left, greaterThanOrEqualTo(306));
      expect(rect.right, lessThanOrEqualTo(390));
      expect(rect.top, greaterThanOrEqualTo(134));
      expect(
        tester.getRect(find.byKey(const ValueKey('providerRouteBody'))).right,
        lessThanOrEqualTo(306),
      );
      expect(find.text('Edit provider'), findsOneWidget);
      // Pixels-exact compare gates to the capturing platform: the baseline
      // was rendered on macOS and Linux font rasterization diffs ~0.24%
      // (the fa_ui CI shard runs on ubuntu; the file name carries no
      // `golden` marker, so the shard's `--exclude golden` does not skip
      // it). The geometric assertions above stay cross-platform.
      if (!kIsWeb && Platform.isMacOS) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/fa_route_header_duo.png'),
        );
      }

      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Duo nested routes expose only the current rail Back', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 59, right: 84);
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        FaDuoLayoutScope(
          geometry: _duoGeometry,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: _automaticHeaderPage)),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(find.text('Choose model'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      expect(tester.getRect(find.byType(BackButton)).left, greaterThan(306));
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Edit provider'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
