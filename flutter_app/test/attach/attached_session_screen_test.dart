// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Widget coverage for the attached-session transcript rows (gh-1848
/// tier 2): every `_AttachedRow.build` branch — user bubble, assistant
/// bubble, tool chip.
///
/// The screen is pure Flutter (no JS engine), so these run on every host —
/// the row builder otherwise rides the attach suites and measured 0% on
/// bridge-less CI runners.
library;

import 'dart:async';

import 'package:fa/services/attached_session_controller.dart';
import 'package:fa/services/cli_session_presence.dart';
import 'package:fa/ui/screens/attached_session_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeEventSource implements SessionEventSource {
  final _controllers = <String, StreamController<AttachedSessionEvent>>{};

  void emit(String sessionId, List<AttachedMessage> appended) {
    (_controllers[sessionId] ??=
            StreamController<AttachedSessionEvent>.broadcast())
        .add(AttachedSessionEvent(appended: appended));
  }

  @override
  Stream<AttachedSessionEvent> watch(String sessionId) {
    return (_controllers[sessionId] ??=
            StreamController<AttachedSessionEvent>.broadcast())
        .stream;
  }

  @override
  Future<void> dispose() async {
    for (final c in _controllers.values) {
      await c.close();
    }
    _controllers.clear();
  }
}

class _FakeInputChannel implements SessionInputChannel {
  @override
  Future<void> send(String sessionId, String text) async {}
}

void main() {
  testWidgets('transcript renders user, assistant, and tool rows', (
    tester,
  ) async {
    final events = _FakeEventSource();
    final controller = AttachedSessionController(
      sessionId: 's1',
      title: 'Demo',
      transport: SessionAttachTransport(
        events: events,
        input: _FakeInputChannel(),
      ),
    );
    events.emit('s1', [
      const AttachedMessage(role: AttachedMessageRole.user, text: 'hi there'),
      const AttachedMessage(
        role: AttachedMessageRole.assistant,
        text: 'hello back',
      ),
      const AttachedMessage(
        role: AttachedMessageRole.tool,
        toolName: 'fetch',
        text: '',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(home: AttachedSessionScreen(controller: controller)),
    );
    await tester.pump();

    expect(find.text('hi there'), findsOneWidget);
    expect(find.text('hello back'), findsOneWidget);
    expect(find.text('[ fetch ]'), findsOneWidget);
  });
}
