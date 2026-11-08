// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

/// The docked Files panel's reveal (user call: the panel popped in and
/// vanished on close while the sidebar glided). The slot plays the SAME
/// 200ms easeInOutCubic slide+fade in BOTH directions —
///   - mid-transition frames exist with an interpolated offset/opacity,
///   - the settled frame matches the old geometry (full width at the
///     window's right edge, flush against the transcript),
///   - the resize handle stays live mid-animation (width drags are never
///     animated).
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

const _panelWidth = 300.0; // kFaChatFilesPanelWidth
const _windowWidth = 1280.0;
const _windowHeight = 800.0;

Finder get _panel => find.byKey(const ValueKey('faChatFilesPanel'));
Finder get _handle =>
    find.byKey(const ValueKey('faChatFilesPanelResizeHandle'));

Future<void> _pumpChat(WidgetTester tester) async {
  final service = FakeChatService();
  addTearDown(service.dispose);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(_windowWidth, _windowHeight);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: FaChatScreen(
        service: service,
        fileBrowserBuilder: (context) => Container(
          key: const ValueKey('filesAppPanel'),
          color: Colors.green,
          // The band's own X closes through the scope (the docked panel's
          // close intent) — exactly what the real Files band wires.
          child: Builder(
            builder: (scopeContext) => TextButton(
              key: const ValueKey('testClosePanel'),
              onPressed: FaFilesPanelScope.maybeOf(scopeContext)?.closePanel,
              child: const Text('close panel'),
            ),
          ),
        ),
      ),
    ),
  );
  // flutter_chat_ui's empty chat list schedules a 50ms timer.
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('open: mid-transition frame slides in, settled frame matches '
      'the old geometry', (tester) async {
    await _pumpChat(tester);
    expect(_panel, findsNothing);

    await tester.tap(find.byTooltip('Open files'));
    // The tap's build frame mounts the slot (reveal 0), the next pump
    // starts the controller; 100ms later the reveal is mid-flight.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_panel, findsOneWidget);
    final mid = tester.getRect(_panel);
    expect(mid.width, greaterThan(1), reason: 'reveal has started');
    expect(mid.width, lessThan(_panelWidth), reason: 'reveal is mid-flight');
    expect(
      mid.right,
      closeTo(_windowWidth, .5),
      reason: 'the slot hugs the window edge at every frame',
    );
    // The content does not reflow mid-flight: the inner surface keeps the
    // final width and slides in from the window edge (a rightward
    // translate carries the overflow; the slot's ClipRect crops it).
    final content = tester.getRect(find.byKey(const ValueKey('filesAppPanel')));
    expect(content.width, _panelWidth, reason: 'content keeps its size');
    // The widget is Transform.translate, so transform.matrix stores the
    // translation in its fourth column.
    final transform = tester
        .widgetList<Transform>(
          find.descendant(of: _panel, matching: find.byType(Transform)),
        )
        .first;
    expect(
      transform.transform.getTranslation().x,
      greaterThan(0),
      reason: 'the pane slides in from the right edge',
    );
    // Fading: the pane is partially transparent mid-flight.
    final opacity = tester
        .widgetList<Opacity>(
          find.descendant(of: _panel, matching: find.byType(Opacity)),
        )
        .first;
    expect(opacity.opacity, greaterThan(0));
    expect(opacity.opacity, lessThan(1));

    await tester.pumpAndSettle();
    final settled = tester.getRect(_panel);
    expect(settled.width, _panelWidth, reason: 'settled at the old width');
    expect(settled.right, closeTo(_windowWidth, .001));
    expect(settled.left, closeTo(_windowWidth - _panelWidth, .001));
    final settledContent = tester.getRect(
      find.byKey(const ValueKey('filesAppPanel')),
    );
    expect(settledContent, settled, reason: 'settled content fills the slot');
  });

  testWidgets('close: the panel slides out instead of vanishing', (
    tester,
  ) async {
    await _pumpChat(tester);
    await tester.tap(find.byTooltip('Open files'));
    await tester.pumpAndSettle();
    expect(_panel, findsOneWidget);

    // Close through the band's X (the scope's close intent) — the header
    // Files entry is hidden while the panel is open.
    await tester.tap(find.byKey(const ValueKey('testClosePanel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-exit the content is still mounted, sliding and fading.
    expect(_panel, findsOneWidget);
    final mid = tester.getRect(_panel);
    expect(mid.width, greaterThan(1));
    expect(mid.width, lessThan(_panelWidth));
    expect(mid.right, closeTo(_windowWidth, .5));

    await tester.pumpAndSettle();
    expect(_panel, findsNothing, reason: 'the exit unmounts at its end');
  });

  testWidgets('the resize handle stays live mid-animation and width drags '
      'are never animated', (tester) async {
    await _pumpChat(tester);
    await tester.tap(find.byTooltip('Open files'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_handle, findsOneWidget, reason: 'handle mounted mid-flight');

    // Drag DURING the transition: the desired width lands without
    // fighting the reveal (the drag does not reset or stall the slide).
    await tester.drag(_handle, const Offset(-120, 0));
    await tester.pumpAndSettle();
    final settled = tester.getSize(_panel);
    expect(settled.width, 420, reason: 'the drag set the final width');
    expect(tester.getRect(_panel).right, closeTo(_windowWidth, .001));
  });

  testWidgets('the shared handle sits FLUSH on the panel edge and '
      'highlights on hover (owner unification)', (tester) async {
    await _pumpChat(tester);
    await tester.tap(find.byTooltip('Open files'));
    await tester.pumpAndSettle();

    // FLUSH: the grip's center lands exactly on the panel's left edge —
    // the seam line — not detached from it.
    final grip = tester.getRect(
      find.descendant(
        of: _handle,
        matching: find.byWidgetPredicate(
          (w) =>
              w is AnimatedContainer &&
              (w.decoration as BoxDecoration?)?.color != Colors.transparent,
        ),
      ),
    );
    final panelLeft = tester.getRect(_panel).left;
    expect(grip.width, 3, reason: 'the shared 3px grip');
    expect(grip.center.dx, closeTo(panelLeft, .5));

    // HOVER: idle paints the hairline grip; hovering the divider
    // highlights it with the accent (the chats divider's interaction).
    Color gripColor() =>
        (tester
                    .widget<AnimatedContainer>(
                      find.descendant(
                        of: _handle,
                        matching: find.byWidgetPredicate(
                          (w) =>
                              w is AnimatedContainer &&
                              (w.decoration as BoxDecoration?)?.color !=
                                  Colors.transparent,
                        ),
                      ),
                    )
                    .decoration!
                as BoxDecoration)
            .color!;

    final tokens = FaDesignTokens.of(tester.element(_handle));
    expect(gripColor(), tokens.hairline, reason: 'idle: the hairline grip');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(_handle));
    await tester.pumpAndSettle();
    expect(
      gripColor(),
      tokens.accent.withValues(alpha: .8),
      reason: 'hover: the accent highlight',
    );

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(gripColor(), tokens.hairline, reason: 'hover out restores idle');
  });
}
