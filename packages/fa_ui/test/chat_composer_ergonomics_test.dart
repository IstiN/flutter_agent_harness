// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// Composer ergonomics (issue #459): the mobile vertical budget (AC1) and
/// the attach glyph's hit target (AC2).
///
/// AC1 is measured the way the grounding screenshot frames it — a phone
/// viewport with the keyboard visible: the composer is docked at the
/// bottom under a simulated inset, the field holds ONE line, and the
/// whole widget's rendered height must stay within a fixed budget. The
/// budget pins the compact single-layer padding: max(48px hit-target
/// buttons, one text line) + 2×4dp outer padding.
void main() {
  testWidgets('AC1: composer height stays within the mobile budget with '
      'the keyboard visible', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 336);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatComposer(
              key: const ValueKey('composer'),
              service: FakeChatService(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final height = tester
        .getSize(find.byKey(const ValueKey('composer')))
        .height;
    // Compact budget: buttons floor the row at 48, outer padding 4+4 —
    // 57dp total (1dp top hairline + 48dp buttons + 4+4dp padding). The pre-fix nested padding
    // (8+12 above and below the text) measures 64dp.
    expect(height, lessThanOrEqualTo(57), reason: 'composer height');
  });

  testWidgets('AC1 E3: without an inset (hardware keyboard) the paddings '
      'stay equally compact', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatComposer(
              key: const ValueKey('composer'),
              service: FakeChatService(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final height = tester
        .getSize(find.byKey(const ValueKey('composer')))
        .height;
    expect(height, lessThanOrEqualTo(57), reason: 'composer height');
  });

  testWidgets('AC2: the attach button keeps a >=36x36 hit target', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // A wired picker makes the built-in attach button render in the
    // leading slot.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatComposer(
              service: FakeChatService(),
              uploadPicker: () async => const [],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The leading-slot IconButton wraps the FaAttachGlyph.
    final button = find.ancestor(
      of: find.byType(FaAttachGlyph),
      matching: find.byType(IconButton),
    );
    expect(button, findsOneWidget);
    final size = tester.getSize(button);
    expect(size.width, greaterThanOrEqualTo(36), reason: 'hit target width');
    expect(size.height, greaterThanOrEqualTo(36), reason: 'hit target height');
  });
}
