// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// The composer-adjacent live status row (issue #865): phase label, current
/// tool, elapsed seconds on a 1 s tick — hidden the frame the run ends.
///
/// Elapsed time is ticker-driven, so `tester.pump` IS the fake clock.
class _PhaseService extends FakeChatService {
  final List<FaChatMessage> rows = [];
  bool streaming = false;
  String? errorText;

  @override
  List<FaChatMessage> get messages => rows;
  @override
  bool get isStreaming => streaming;
  @override
  String? get error => errorText;

  void notify() => notifyListeners();
}

Future<void> _pump(WidgetTester tester, _PhaseService service) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: FaChatScreen(service: service)));
  // flutter_chat_ui's empty chat list schedules a 50ms timer; settle it
  // WITHOUT crossing a ticker second (the elapsed display must stay 0s).
  await tester.pump(const Duration(milliseconds: 100));
  // Unmount before teardown so no active ticker/timer survives the test.
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
}

void main() {
  const content = ValueKey('faChatRunStatusContent');

  testWidgets('idle: the row renders nothing', (tester) async {
    final service = _PhaseService();
    await _pump(tester, service);
    expect(find.byKey(content), findsNothing);
  });

  testWidgets('AC1: provider wait shows thinking with elapsed seconds', (
    tester,
  ) async {
    final service = _PhaseService()
      ..rows.add(FaChatMessage(role: 'user', content: 'fix the tests'))
      ..streaming = true
      ..notify();
    await _pump(tester, service);

    expect(find.textContaining('Thinking'), findsOneWidget);
    expect(find.textContaining('· 0s'), findsOneWidget);
    // No events for 3s: the elapsed clock keeps ticking (fake clock).
    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('· 3s'), findsOneWidget);
  });

  testWidgets('AC2: tool start names the tool and switches per tool', (
    tester,
  ) async {
    final service = _PhaseService()
      ..rows.add(FaChatMessage(role: 'user', content: 'tidy the repo'))
      ..streaming = true
      ..notify();
    await _pump(tester, service);
    // Request out, nothing running yet: the provider wait.
    expect(find.textContaining('Thinking'), findsOneWidget);

    service.rows.add(
      FaChatMessage(
        role: 'system',
        content: '[wasm_shell] {"argv": ["true"]}',
      ),
    );
    service.notify();
    await tester.pump();
    expect(find.textContaining('Running wasm_shell'), findsOneWidget);

    // true ends, wc starts: the row switches names with the phase.
    service.rows
      ..add(FaChatMessage(role: 'tool', content: '', toolName: 'wasm_shell'))
      ..add(FaChatMessage(role: 'system', content: '[wc] {"stdin": "x"}'));
    service.notify();
    await tester.pump();
    expect(find.textContaining('Running wc'), findsOneWidget);
    expect(find.textContaining('wasm_shell'), findsNothing);
  });

  testWidgets('AC3: stream deltas flip the row to writing', (tester) async {
    final service = _PhaseService()
      ..rows.add(FaChatMessage(role: 'user', content: 'hi'))
      ..streaming = true;
    await _pump(tester, service);

    service.rows.add(
      FaChatMessage(role: 'assistant', content: 'partial ans'),
    );
    service.notify();
    await tester.pump();
    expect(find.textContaining('Writing'), findsOneWidget);
    // The in-list typing footer is still the only «Fa is typing...» surface.
    expect(find.text('Fa is typing...'), findsOneWidget);
  });

  testWidgets('AC4: run end hides the row within one frame', (tester) async {
    final service = _PhaseService()
      ..rows.add(FaChatMessage(role: 'user', content: 'hi'))
      ..streaming = true
      ..notify();
    await _pump(tester, service);
    expect(find.byKey(content), findsOneWidget);

    service
      ..streaming = false
      ..notify();
    await tester.pump();
    expect(find.byKey(content), findsNothing);
    // The clock is reset for the next run.
    service
      ..streaming = true
      ..notify();
    await tester.pump();
    expect(find.textContaining('· 0s'), findsOneWidget);
  });

  testWidgets('E1: parallel tools show count + first name, no flicker', (
    tester,
  ) async {
    final service = _PhaseService()
      ..rows.addAll([FaChatMessage(role: 'user', content: 'refactor')])
      ..streaming = true
      ..notify();
    await _pump(tester, service);

    service.rows.add(
      FaChatMessage(role: 'system', content: '[read] {"path": "a"}'),
    );
    service.notify();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    service.rows.add(
      FaChatMessage(role: 'system', content: '[grep] {"pattern": "F"}'),
    );
    service.notify();
    await tester.pump();
    expect(find.textContaining('Running read ×2'), findsOneWidget);

    // One finishes: count narrows but the elapsed clock keeps running.
    service.rows.add(
      FaChatMessage(role: 'tool', content: 'ok', toolName: 'grep'),
    );
    service.notify();
    await tester.pump();
    expect(find.textContaining('Running read · 2s'), findsOneWidget);
  });

  testWidgets('E2: steering mid-run keeps the row up', (tester) async {
    final service = _PhaseService()
      ..rows.addAll([
        FaChatMessage(role: 'user', content: 'go'),
        FaChatMessage(role: 'system', content: '[bash] {"command": "ls"}'),
      ])
      ..streaming = true
      ..notify();
    await _pump(tester, service);

    service.rows.add(
      FaChatMessage(role: 'user', content: 'also check the logs'),
    );
    service.notify();
    await tester.pump();
    expect(find.byKey(content), findsOneWidget);
  });

  testWidgets('E3: error turn hides the row, error surface unchanged', (
    tester,
  ) async {
    final service = _PhaseService()
      ..rows.add(FaChatMessage(role: 'user', content: 'hi'))
      ..streaming = true
      ..notify();
    await _pump(tester, service);
    expect(find.byKey(content), findsOneWidget);

    service
      ..streaming = false
      ..errorText = 'provider exploded: 502'
      ..notify();
    await tester.pump();
    expect(find.byKey(content), findsNothing);
    expect(find.textContaining('provider exploded'), findsOneWidget);
  });

  testWidgets('E4: a very long run keeps ticking with no timeout', (
    tester,
  ) async {
    final service = _PhaseService()
      ..rows.add(FaChatMessage(role: 'user', content: 'big migration'))
      ..streaming = true
      ..notify();
    await _pump(tester, service);

    await tester.pump(const Duration(minutes: 10));
    expect(find.textContaining('· 600s'), findsOneWidget);
  });
}
