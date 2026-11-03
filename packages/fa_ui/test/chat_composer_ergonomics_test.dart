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
/// budget pins the compact single-layer padding: a 36px control/one-line
/// row plus 2+2px row padding, with floating margins outside the surface.
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
    // 40px surface + 4px top separation + 8px outer bottom margin.
    expect(height, 52, reason: 'composer height including floating margins');
    expect(
      tester.getSize(find.byKey(const ValueKey('faChatFloatingComposer'))),
      const Size(390 - 16, 40),
      reason: '40px single-line surface inside 8px horizontal margins',
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('faChatComposerFieldRow')))
          .height,
      40,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('faChatComposerSendButton'))),
      const Size(40, 32),
      reason: 'the send oval: 40x32 (Telegram-style), not a circle',
    );
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
    expect(height, 52, reason: 'composer height including floating margins');
    expect(
      tester
          .getSize(find.byKey(const ValueKey('faChatComposerFieldRow')))
          .height,
      40,
    );
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
    expect(
      size,
      const Size.square(36),
      reason: 'compact accessible hit target',
    );
  });

  testWidgets('multiline grows to six lines then scrolls at the same height', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatComposer(service: FakeChatService()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('faChatComposerTextField'));
    final row = find.byKey(const ValueKey('faChatComposerFieldRow'));
    await tester.enterText(
      field,
      List.generate(6, (i) => 'line $i').join('\n'),
    );
    await tester.pump();
    final sixLineHeight = tester.getSize(row).height;
    expect(sixLineHeight, greaterThan(40));
    await tester.enterText(
      field,
      List.generate(8, (i) => 'line $i').join('\n'),
    );
    await tester.pump();
    expect(tester.getSize(row).height, sixLineHeight);
    final send = tester.getRect(
      find.byKey(const ValueKey('faChatComposerSendButton')),
    );
    final surface = tester.getRect(
      find.byKey(const ValueKey('faChatFloatingComposer')),
    );
    expect(surface.contains(send.center), isTrue);
    expect(send.size, const Size(40, 32));
  });

  testWidgets('AC5: the placeholder starts at the kit iconSpacing norm from '
      'the attach glyph (owner call: the old reserved-but-unrendered slot '
      'pushed the hint ~60px from the pill edge)', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // A wired picker renders the built-in attach (plus) button in the
    // leading slot — the prefix icon the dead zone was measured after.
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

    final surface = tester.getRect(
      find.byKey(const ValueKey('faChatFloatingComposer')),
    );
    final attach = tester.getRect(
      find.byKey(const ValueKey('faChatComposerAttachButton')),
    );
    final hint = tester.getRect(find.text('Type a message'));

    // Icon-to-text gap: the field's content starts within the kit's
    // iconSpacing norm (8-12px) of the prefix icon's right edge.
    final gap = hint.left - attach.right;
    expect(gap, greaterThanOrEqualTo(8));
    expect(gap, lessThanOrEqualTo(16), reason: 'icon-to-text gap ≈ 10px');
    // Field-left padding: the pill's leading edge to the prefix icon is
    // the 12-16px norm.
    final fieldLeft = attach.left - surface.left;
    expect(fieldLeft, greaterThanOrEqualTo(12));
    expect(fieldLeft, lessThanOrEqualTo(16));
    // The whole leading inset (pill edge → caret) is fully accounted:
    // 12px field-left + the 36px hit target + the 10px gap = 58. The old
    // compact build put the caret 70px out with a 22px icon-to-text gap.
    expect(hint.left - surface.left, closeTo(58, .5));
  });
}
