import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa/services/attached_session_controller.dart';
import 'package:fa/services/cli_session_presence.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fakes for the attach-transport interfaces: the event source replays
/// scripted batches, the input channel records handed-over user input.
class _FakeEventSource implements SessionEventSource {
  final _controllers = <String, StreamController<AttachedSessionEvent>>{};

  void emit(String sessionId, List<AttachedMessage> appended) {
    _controllers[sessionId]?.add(AttachedSessionEvent(appended: appended));
  }

  @override
  Stream<AttachedSessionEvent> watch(String sessionId) {
    final existing = _controllers[sessionId];
    if (existing != null) return existing.stream;
    return (_controllers[sessionId] =
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
  final sent = <(String, String)>[];

  @override
  Future<void> send(String sessionId, String text) async {
    sent.add((sessionId, text));
  }
}

void main() {
  test(
    'the controller follows events and hands input to the channel',
    () async {
      final events = _FakeEventSource();
      final input = _FakeInputChannel();
      final controller = AttachedSessionController(
        sessionId: 'sess-1',
        title: 'Work session',
        transport: SessionAttachTransport(events: events, input: input),
      );

      // Backlog arrives through the watch stream.
      events.emit('sess-1', [
        const AttachedMessage(role: AttachedMessageRole.user, text: 'hi'),
        const AttachedMessage(
          role: AttachedMessageRole.assistant,
          text: 'hello',
        ),
        const AttachedMessage(
          role: AttachedMessageRole.tool,
          text: '',
          toolName: 'read',
        ),
      ]);
      await pumpEventQueue();
      expect(controller.rows, hasLength(3));
      expect(controller.rows.first.text, 'hi');

      // Composer input goes through the channel addressed to the session.
      await controller.send('typed in the app');
      expect(input.sent, [('sess-1', 'typed in the app')]);
      expect(controller.sending, isFalse);

      // Blank input is ignored.
      await controller.send('   ');
      expect(input.sent, hasLength(1));

      controller.dispose();
      await events.dispose();
    },
  );

  test(
    'CliSessionPresence reflects the store and notifies on change',
    () async {
      final store = _FakePresenceStore();
      final service = CliSessionPresence.forTest(store);
      await pumpEventQueue();
      expect(service.isLive('s1'), isTrue);
      expect(service.isLive('gone'), isFalse);

      store.live = const {};
      await service.refreshForTest();
      expect(service.isLive('s1'), isFalse);
      service.dispose();
    },
  );
}

class _FakePresenceStore implements SessionPresenceStore {
  var live = <String, SessionPresence>{
    's1': SessionPresence(
      sessionId: 's1',
      startedAt: '2026-01-01T00:00:00Z',
      touchedAt: '2026-01-01T00:00:00Z',
    ),
  };

  @override
  Future<void> register(String sessionId, {int? pid, String? host}) async {
    live = {
      ...live,
      sessionId: SessionPresence(
        sessionId: sessionId,
        startedAt: '2026-01-01T00:00:00Z',
        touchedAt: '2026-01-01T00:00:00Z',
      ),
    };
  }

  @override
  Future<void> touch(String sessionId) async {}

  @override
  Future<void> unregister(String sessionId) async {
    live = {...live}..remove(sessionId);
  }

  @override
  Future<Map<String, SessionPresence>> list() async => live;
}
