import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Recording fake over the [MessagingRepository] interface.
final class _RecordingRepo implements MessagingRepository {
  final sent = <AgentMessage>[];
  final registered = <String>[];
  final touched = <String>[];

  @override
  Future<void> register(String agentId, {String? sessionName}) async =>
      registered.add(agentId);

  @override
  Future<void> touch(String agentId) async => touched.add(agentId);

  @override
  Future<void> send(AgentMessage message) async => sent.add(message);

  @override
  Future<List<AgentMessage>> peek(String agentId) async => const [];

  @override
  Future<List<AgentMessage>> drain(String agentId) async => const [];

  @override
  Future<List<MailboxEntry>> directory() async => const [];
}

void main() {
  test('send/register delegate to the CURRENT repo, swap re-points them', () {
    final first = _RecordingRepo();
    final second = _RecordingRepo();
    final fabric = SwappableMessagingRepository(first);

    // Before the swap everything lands on the initial delegate.
    fabric.register('main');
    expect(first.registered, ['main']);
    expect(second.registered, isEmpty);

    final message = AgentMessage(
      id: 'm1',
      fromId: 'app',
      toId: 'session/main',
      text: 'hi',
      sentAt: '2026-01-01T00:00:00Z',
    );
    fabric.send(message);
    expect(first.sent, [message]);

    // The session-root fallback swaps the fabric onto the new root; later
    // traffic must reach ONLY the replacement.
    fabric.swap(second);
    fabric.register('main');
    expect(second.registered, ['main']);
    expect(first.registered, hasLength(1));
  });

  test('touch delegates to the CURRENT repo', () {
    final first = _RecordingRepo();
    final second = _RecordingRepo();
    final fabric = SwappableMessagingRepository(first);
    fabric.touch('main');
    expect(first.touched, ['main']);
    fabric.swap(second);
    fabric.touch('main');
    expect(first.touched, hasLength(1));
    expect(second.touched, ['main']);
  });
}
