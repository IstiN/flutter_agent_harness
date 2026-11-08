// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

final class _AvailableVoiceInput implements FaChatVoiceInput {
  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => null;
  @override
  Future<bool> start() async => true;
  @override
  Future<String?> stopAndTranscribe() async => null;
  @override
  Future<void> cancel() async {}
}

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
    final sendSize = tester.getSize(
      find.byKey(const ValueKey('faChatComposerSendButton')),
    );
    expect(
      sendSize,
      const Size(40, 34),
      reason:
          'the send capsule: 40x34 (2px vertical inset in the pill), '
          'not a circle',
    );
    // The capsule keeps 4px of trailing optical air and stays vertically
    // centered, with a corner radius concentric to the pill's.
    final sendRect = tester.getRect(
      find.byKey(const ValueKey('faChatComposerSendButton')),
    );
    final surfaceRect = tester.getRect(
      find.byKey(const ValueKey('faChatFloatingComposer')),
    );
    expect(surfaceRect.right - sendRect.right, 4, reason: 'trailing air');
    expect(sendRect.center.dy, surfaceRect.center.dy, reason: 'centered');
    final clip = tester.widget<ClipRRect>(
      find.descendant(
        of: find.byKey(const ValueKey('faChatComposerSendButton')),
        matching: find.byType(ClipRRect),
      ),
    );
    expect(clip.borderRadius, BorderRadius.circular(17));

    // Material's unrotated plane is horizontal. Keep it exactly centered,
    // with no offset or rotation that would make it point up or down.
    final glyphFinder = find.byKey(const ValueKey('faChatComposerSendGlyph'));
    tester.widget<Center>(glyphFinder);
    expect(
      find.descendant(of: glyphFinder, matching: find.byType(Transform)),
      findsNothing,
    );
    expect(tester.getRect(glyphFinder).center, sendRect.center);
    final glow = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('faChatComposerSendGlow')),
    );
    final shadow = (glow.decoration as BoxDecoration).boxShadow!.single;
    expect(shadow.blurRadius, 8);
    expect(shadow.color.a, closeTo(.14, .001));
    final plane = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('faChatComposerSendGlyph')),
        matching: find.byIcon(Icons.send_rounded),
      ),
    );
    expect(plane.size, 24);
    expect(sendSize, const Size(40, 34), reason: 'capsule geometry is fixed');
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
    expect(send.size, const Size(40, 34));
  });

  testWidgets('AC5: attachment is an edge control with the standard text gap', (
    tester,
  ) async {
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

    // The caret follows the attachment closely: the field adds only a
    // 4px optical gap after the 36px prefix target.
    final gap = hint.left - attach.right;
    expect(gap, closeTo(4, .5));
    // The attachment hit target sits at the same 2px edge inset as Send.
    expect(attach.left - surface.left, 2);
    // 2px edge + 36px target + 4px decorator gap = 42px to the hint/caret.
    expect(hint.left - surface.left, closeTo(42, .5));
  });

  testWidgets('mic and Send retain 36/40px targets with one compact 4px gap', (
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
            child: ChatComposer(
              service: FakeChatService(),
              voiceInput: _AvailableVoiceInput(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final mic = tester.getRect(find.byTooltip('Voice input'));
    final send = tester.getRect(
      find.byKey(const ValueKey('faChatComposerSendButton')),
    );
    expect(mic.size, const Size.square(36));
    expect(send.size, const Size(40, 34));
    expect(send.left - mic.right, 4);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('faChatComposerFieldRow')))
          .height,
      40,
    );
  });
}
