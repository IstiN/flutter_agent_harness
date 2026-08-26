import 'dart:async';

import 'package:fa/services/attached_session_controller.dart';
import 'package:fa/services/cli_session_presence.dart';
import 'package:fa/ui/screens/attached_session_screen.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// Golden frames for the attached-CLI-session view: a live session a
/// `fa` CLI owns, followed 1:1 from the app with input hand-over.
void main() {
  setUpAll(ensureGoldenFonts);

  testWidgets('attached session screen: transcript + composer', (tester) async {
    final controller = AttachedSessionController(
      sessionId: 'sess-golden',
      title: 'flutter_agent',
      transport: _FixedTransport([
        const AttachedMessage(
          role: AttachedMessageRole.user,
          text: 'fix the failing provider test and run the suite',
        ),
        const AttachedMessage(
          role: AttachedMessageRole.assistant,
          text:
              'Fixed the registry lookup in provider_commands.dart — the '
              'second account kept overwriting the first key slot. The '
              'suite is green (2992 passed).',
        ),
        const AttachedMessage(
          role: AttachedMessageRole.tool,
          text: '',
          toolName: 'edit',
        ),
        const AttachedMessage(
          role: AttachedMessageRole.assistant,
          text: 'The edit applied cleanly; anything else?',
        ),
      ]),
    );
    await pumpGolden(
      tester,
      AttachedSessionScreen(controller: controller),
      size: goldenSizePhone,
      wrap: (child) => child,
    );
    await expectGolden(tester, 'attached_session_phone');
    controller.dispose();
  });

  testWidgets('attached session screen: empty state', (tester) async {
    final controller = AttachedSessionController(
      sessionId: 'sess-empty',
      title: 'fresh session',
      transport: _FixedTransport(const []),
    );
    await pumpGolden(
      tester,
      AttachedSessionScreen(controller: controller),
      size: goldenSizePhone,
      wrap: (child) => child,
    );
    await expectGolden(tester, 'attached_session_empty');
    controller.dispose();
  });
}

/// Replays a fixed backlog once, records input.
class _FixedTransport implements SessionAttachTransport {
  _FixedTransport(this.rows);

  final List<AttachedMessage> rows;
  final sent = <(String, String)>[];

  @override
  SessionEventSource get events => _FixedSource(rows);

  @override
  SessionInputChannel get input => _RecordingChannel(sent);
}

class _FixedSource implements SessionEventSource {
  _FixedSource(this.rows);

  final List<AttachedMessage> rows;

  @override
  Stream<AttachedSessionEvent> watch(String sessionId) async* {
    if (rows.isNotEmpty) yield AttachedSessionEvent(appended: rows);
  }

  @override
  Future<void> dispose() async {}
}

class _RecordingChannel implements SessionInputChannel {
  _RecordingChannel(this.sent);

  final List<(String, String)> sent;

  @override
  Future<void> send(String sessionId, String text) async {
    sent.add((sessionId, text));
  }
}
