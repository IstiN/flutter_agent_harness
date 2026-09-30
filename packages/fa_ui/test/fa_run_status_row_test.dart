// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// The single transient status row (issues #865, #1042): phase label,
/// current tool, elapsed seconds on a 1 s tick — mounted as the
/// transcript's visually-last entry, hidden the frame the run ends.
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
      FaChatMessage(role: 'system', content: '[wasm_shell] {"argv": ["true"]}'),
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

  testWidgets('AC3: stream deltas flip the row to typing', (tester) async {
    final service = _PhaseService()
      ..rows.add(FaChatMessage(role: 'user', content: 'hi'))
      ..streaming = true;
    await _pump(tester, service);

    service.rows.add(FaChatMessage(role: 'assistant', content: 'partial ans'));
    service.notify();
    await tester.pump();
    // Issue #1042 fix contract: token emission reads «Fa is typing...» —
    // the retired typing footer's string, reused on the single row.
    expect(find.textContaining('Fa is typing'), findsOneWidget);
  });

  testWidgets('#1042 I1: exactly ONE status row in every run phase — '
      'thinking, typing, tool', (tester) async {
    final service = _PhaseService()
      ..rows.add(FaChatMessage(role: 'user', content: 'fix the tests'))
      ..streaming = true
      ..notify();
    await _pump(tester, service);

    // Pre-first-token: the thinking label with the timer.
    expect(find.byKey(content), findsOneWidget);
    expect(find.textContaining('Thinking'), findsOneWidget);
    expect(find.textContaining('· 0s'), findsOneWidget);

    // Token emission: still exactly one row, now the typing label.
    service.rows.add(FaChatMessage(role: 'assistant', content: 'partial'));
    service.notify();
    await tester.pump();
    expect(find.byKey(content), findsOneWidget);
    expect(find.textContaining('Fa is typing'), findsOneWidget);

    // Tool phase: still exactly one row.
    service.rows.add(
      FaChatMessage(role: 'system', content: '[bash] {"command": "ls"}'),
    );
    service.notify();
    await tester.pump();
    expect(find.byKey(content), findsOneWidget);
    expect(find.textContaining('Running bash'), findsOneWidget);
    // The transcript mounts exactly one row widget (the retired typing
    // footer's key renders nothing anywhere).
    expect(find.byKey(const ValueKey('faChatRunStatusRow')), findsOneWidget);
    expect(find.byKey(const ValueKey('faChatTypingFooter')), findsNothing);
  });

  testWidgets('#1042 I2: the row is the transcript last entry — inside '
      'the scrollable, no composer-docked badge', (tester) async {
    final service = _PhaseService()
      ..rows.add(FaChatMessage(role: 'user', content: 'hello'))
      ..streaming = true
      ..notify();
    await _pump(tester, service);

    final row = find.byKey(content);
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: find.byType(Scrollable), matching: row),
      findsOneWidget,
    );
    // One label surface only — nothing outside the scrollable.
    expect(find.textContaining('Thinking'), findsOneWidget);
  });

  testWidgets('#1042: on completion the row is replaced by the assistant '
      'message — no gap, no lingering row', (tester) async {
    final service = _PhaseService()
      ..rows.add(FaChatMessage(role: 'user', content: 'hi'))
      ..streaming = true
      ..notify();
    await _pump(tester, service);
    expect(find.byKey(content), findsOneWidget);

    // The assistant message lands while the run is still open: the row
    // stays up beneath it (the visually-last entry).
    service.rows.add(FaChatMessage(role: 'assistant', content: 'all done'));
    service.notify();
    await tester.pump();
    // The list's 250 ms insert animation settles the new tile.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(content), findsOneWidget);
    expect(find.text('all done', findRichText: true), findsOneWidget);

    // Run end: the row goes the same frame — the assistant message is the
    // last entry, nothing dangles.
    service
      ..streaming = false
      ..notify();
    await tester.pump();
    expect(find.byKey(content), findsNothing);
    expect(find.text('all done', findRichText: true), findsOneWidget);
    expect(find.textContaining('Fa is typing'), findsNothing);
  });

  testWidgets('#1042 E1: empty transcript + run — the row is the only item '
      '(the package "No messages yet" overlay is suppressed)', (tester) async {
    final service = _PhaseService()
      ..streaming = true
      ..notify();
    await _pump(tester, service);

    expect(find.byKey(content), findsOneWidget);
    expect(find.text('No messages yet'), findsNothing);
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
