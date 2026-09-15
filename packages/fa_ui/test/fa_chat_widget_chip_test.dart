// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_chat_ui/flutter_chat_ui.dart' show Chat;
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// Issue #379: the chat never auto-scrolls PAST a live (un-interacted)
/// dynamic widget on narrow viewports, and a pinned bottom chip
/// («✦ Open widget as app») opens it ephemerally or scrolls to it.
///
/// [FakeChatService] is a stub with `messages => const []`; this fake adds
/// the mutable transcript and streaming flag the widget turn needs.
class _WidgetService extends FakeChatService {
  List<FaChatMessage> msgs = const [];
  bool streaming = false;

  @override
  List<FaChatMessage> get messages => msgs;
  @override
  bool get isStreaming => streaming;

  void append(FaChatMessage message) {
    msgs = [...msgs, message];
    notifyListeners();
  }
}

FaChatMessage _user(String text) => FaChatMessage(role: 'user', content: text);
FaChatMessage _widget(String id) =>
    FaChatMessage(role: 'widget', content: '', data: id);
FaChatMessage _text(String text) =>
    FaChatMessage(role: 'assistant', content: text);

Finder _tile(String id) => find.byKey(ValueKey('tile-$id'));
Finder _chip() => find.byKey(const Key('fa-widget-open-chip'));
Finder _chipDismiss() => find.byKey(const Key('fa-widget-open-chip-dismiss'));

Future<void> _pump(
  WidgetTester tester,
  _WidgetService service, {
  Size size = const Size(390, 844),
  Future<bool> Function(FaChatMessage message)? onOpen,
  Widget Function(BuildContext, FaChatMessage)? tileBuilder,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: FaChatScreen(
        service: service,
        dynamicWidgetTileBuilder:
            tileBuilder ??
            (_, message) => Container(
              key: ValueKey('tile-${message.data}'),
              height: 140,
              alignment: Alignment.center,
              child: Text('WIDGET:${message.data}'),
            ),
        onOpenWidgetAsApp: onOpen,
      ),
    ),
  );
  // flutter_chat_ui's chat list schedules an initial-scroll timer.
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('AC1 UT-clamp: streaming text after a live widget keeps its '
      'leading edge inside the viewport (phone width)', (tester) async {
    final service = _WidgetService()..msgs = [_user('сделай'), _widget('w1')];
    await _pump(tester, service);
    expect(tester.getRect(_tile('w1')).top, greaterThanOrEqualTo(0));

    for (var i = 0; i < 20; i++) {
      service.append(_text('chunk $i — a streaming delta line of text'));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(_tile('w1')).top,
        greaterThanOrEqualTo(0),
        reason: 'after chunk $i the widget scrolled fully above the fold',
      );
    }
  });

  testWidgets('AC2 UT-manual-wins: a user scroll during the clamp exits '
      'following; the clamp never fights the user', (tester) async {
    final service = _WidgetService()..msgs = [_user('сделай'), _widget('w1')];
    await _pump(tester, service);
    // Stream enough text for the clamp to engage: it carries the
    // viewport past the near-bottom latch while holding the widget
    // near the top of the view.
    for (var i = 0; i < 12; i++) {
      service.append(_text('chunk $i — a streaming delta line of text'));
      await tester.pumpAndSettle();
    }
    final pos = Scrollable.of(tester.element(_tile('w1'))).position;
    expect(
      pos.pixels,
      greaterThan(100),
      reason: 'precondition: the clamp carries the viewport past the latch',
    );
    expect(
      tester.getRect(_tile('w1')).top,
      inInclusiveRange(-200, 100),
      reason: 'precondition: the clamp holds the widget in view',
    );

    // The user scrolls towards older messages: following exits as today.
    await tester.drag(find.byType(Chat), const Offset(0, 150));
    await tester.pumpAndSettle();
    final afterDrag = pos.pixels;

    for (var i = 12; i < 17; i++) {
      service.append(_text('chunk $i — a streaming delta line of text'));
      await tester.pumpAndSettle();
    }
    expect(
      pos.pixels,
      inInclusiveRange(afterDrag - 1, afterDrag + 1),
      reason:
          'the clamp never fights the user: the viewport stays where '
          'the user left it while new content streams in',
    );
  });

  testWidgets('AC3 UT-chip: chip shows for the live widget, tap opens '
      'ephemerally, touch on the widget auto-hides, × dismisses, a new '
      'turn re-arms (E3)', (tester) async {
    final opened = <String>[];
    final service = _WidgetService()..msgs = [_user('сделай'), _widget('w1')];
    await _pump(
      tester,
      service,
      onOpen: (message) async {
        opened.add(message.data!.toString());
        return true;
      },
    );
    expect(_chip(), findsOneWidget);

    await tester.tap(_chip());
    await tester.pumpAndSettle();
    expect(opened, ['w1']);
    // The chip outlives the clamp (GOAL §2: visible until dismissed or
    // interacted with).
    expect(_chip(), findsOneWidget);

    // A touch on the widget row is an interaction: the chip auto-hides.
    await tester.tap(_tile('w1'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_chip(), findsNothing);

    // × dismisses for that message; more streaming in the turn does not
    // re-show it (E3).
    service.append(_user('ещё'));
    service.append(_widget('w2'));
    await tester.pumpAndSettle();
    expect(_chip(), findsOneWidget);
    await tester.tap(_chipDismiss());
    await tester.pumpAndSettle();
    expect(_chip(), findsNothing);
    for (var i = 0; i < 4; i++) {
      service.append(_text('chunk $i'));
      await tester.pumpAndSettle();
    }
    expect(_chip(), findsNothing);

    // A NEW dynamic message in a later turn re-arms everything (E3).
    service.append(_user('и снова'));
    service.append(_widget('w3'));
    await tester.pumpAndSettle();
    expect(_chip(), findsOneWidget);
    await tester.tap(_chip());
    await tester.pumpAndSettle();
    expect(opened, ['w1', 'w3']);
  });

  testWidgets('E1: clamp and chip target the newest un-interacted widget, '
      'then re-target the older live one after interaction', (tester) async {
    final opened = <String>[];
    final service = _WidgetService()
      ..msgs = [_user('два'), _widget('w1'), _widget('w2')];
    await _pump(
      tester,
      service,
      onOpen: (message) async {
        opened.add(message.data!.toString());
        return true;
      },
    );
    await tester.tap(_chip());
    await tester.pumpAndSettle();
    expect(opened, ['w2'], reason: 'the chip targets the newest widget');

    // Interact with w2: the chip re-targets the older live w1.
    await tester.tap(_tile('w2'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_chip(), findsOneWidget);
    await tester.tap(_chip());
    await tester.pumpAndSettle();
    expect(opened, ['w2', 'w1']);
  });

  testWidgets('chip falls back to scroll-to-widget when ephemeral open is '
      'unavailable on the surface', (tester) async {
    // A pre-seeded transcript where the widget already sits far above
    // the fold (no streaming): the row is off the built window, the
    // chip is the only way back to it.
    final service = _WidgetService()
      ..msgs = [
        _user('сделай'),
        _widget('w1'),
        for (var i = 0; i < 30; i++)
          _text('chunk $i — a streaming delta line of text'),
      ];
    await _pump(tester, service);
    expect(tester.any(_tile('w1')), isFalse, reason: 'precondition');
    expect(_chip(), findsOneWidget);

    await tester.tap(_chip(), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(tester.getRect(_tile('w1')).top, greaterThanOrEqualTo(0));
  });

  testWidgets('AC4 UT-desktop: wide viewport keeps today\'s tail-following '
      '— no clamp, no chip', (tester) async {
    final service = _WidgetService()..msgs = [_user('сделай'), _widget('w1')];
    await _pump(tester, service, size: const Size(1400, 900));
    expect(_chip(), findsNothing);
    for (var i = 0; i < 20; i++) {
      service.append(_text('chunk $i — a streaming delta line of text'));
      await tester.pumpAndSettle();
    }
    expect(_chip(), findsNothing);
    // Unclamped: the widget is either pushed out of the built window or
    // sits above the fold — never held at the viewport top.
    if (tester.any(_tile('w1'))) {
      expect(tester.getRect(_tile('w1')).top, lessThanOrEqualTo(0));
    }
  });

  testWidgets('E2: a widget taller than the viewport keeps its top '
      'visible while the turn streams', (tester) async {
    final service = _WidgetService()..msgs = [_user('сделай'), _widget('w1')];
    await _pump(
      tester,
      service,
      tileBuilder: (_, m) => Container(
        key: ValueKey('tile-${m.data}'),
        height: 1000,
        alignment: Alignment.center,
        child: Text('W:${m.data}'),
      ),
    );
    for (var i = 0; i < 12; i++) {
      service.append(_text('chunk $i — a streaming delta line of text'));
      await tester.pumpAndSettle();
    }
    expect(
      tester.getRect(_tile('w1')).top,
      inInclusiveRange(0, 843),
      reason:
          'the clamp keeps the tall widget\'s top edge inside the '
          'viewport (its bottom may extend below the fold)',
    );
  });
}
