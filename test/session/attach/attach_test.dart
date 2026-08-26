import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  _attachRowGroup();
  group('AgentMessage.kind', () {
    test('round-trips a user-kind message', () {
      final message = AgentMessage(
        id: 'm1',
        fromId: 'app',
        toId: 'sess/main',
        text: 'hello from the app',
        sentAt: '2026-01-01T00:00:00Z',
        kind: AgentMessageKind.user,
      );
      final restored = AgentMessage.fromJson(message.toJson());
      expect(restored.kind, AgentMessageKind.user);
      expect(restored.text, 'hello from the app');
      // The kind field is serialized (it is not the default).
      expect(message.toJson()['kind'], 'user');
    });

    test('agent kind is the default and omitted from json', () {
      final message = AgentMessage(
        id: 'm2',
        fromId: 'main',
        toId: 'other/main',
        text: 'agent chat',
        sentAt: '2026-01-01T00:00:00Z',
      );
      expect(message.kind, AgentMessageKind.agent);
      // Older writers produced no `kind` — the agent default must not
      // bloat every envelope.
      expect(message.toJson().containsKey('kind'), isFalse);
      // Backward compatibility: an envelope without `kind` parses as
      // agent chat.
      final legacy = AgentMessage.fromJson({
        'id': 'm3',
        'fromId': 'main',
        'toId': 'other/main',
        'text': 'legacy',
        'sentAt': '2026-01-01T00:00:00Z',
        'hops': 0,
      });
      expect(legacy.kind, AgentMessageKind.agent);
    });
  });

  group('FileSessionPresenceStore', () {
    late MemoryExecutionEnv env;
    var clock = DateTime.utc(2026, 1, 1, 12);

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      clock = DateTime.utc(2026, 1, 1, 12);
    });

    FileSessionPresenceStore store({
      Duration stale = const Duration(seconds: 15),
    }) => FileSessionPresenceStore(
      env: env,
      root: '/sessions',
      now: () => clock,
      staleAfter: stale,
    );

    test(
      'register → list shows the session live; unregister removes it',
      () async {
        final s = store();
        await s.register('session-1', pid: 42, host: 'mac');
        final live = await s.list();
        expect(live.keys, ['session-1']);
        expect(live['session-1']!.pid, 42);
        expect(live['session-1']!.host, 'mac');

        await s.unregister('session-1');
        expect(await s.list(), isEmpty);
        // Unregistering an absent session is a no-op.
        await s.unregister('session-1');
      },
    );

    test('a stale heartbeat is treated as dead (crash recovery)', () async {
      final s = store();
      await s.register('session-1');
      // Advance past the staleness window without touching.
      clock = clock.add(const Duration(seconds: 16));
      expect(await s.list(), isEmpty, reason: 'crashed process is not live');
    });

    test('touch refreshes the heartbeat within the window', () async {
      final s = store();
      await s.register('session-1');
      clock = clock.add(const Duration(seconds: 10));
      await s.touch('session-1');
      clock = clock.add(const Duration(seconds: 10));
      expect(
        await s.list(),
        isNotEmpty,
        reason: 'touch keeps the session live across the window',
      );
      // A touch for an unknown session is a no-op (no file appears).
      await s.touch('unknown');
      clock = clock.add(const Duration(seconds: 1));
      expect((await s.list()).keys, isNot(contains('unknown')));
    });

    test(
      'list over an empty root answers empty without creating files',
      () async {
        final s = store();
        expect(await s.list(), isEmpty);
      },
    );
  });

  group('FileSessionEventSource + FileSessionInputChannel', () {
    late MemoryExecutionEnv env;
    late FileMessagingRepository fabric;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      fabric = FileMessagingRepository(env: env, root: '/sessions/mail');
    });

    test('watch emits the backlog and follows appended rows', () async {
      // A session file with one user row.
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final created = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work', id: 'sess-a'),
      );
      await created.appendMessage(UserMessage.text('first question'));
      final path = (await created.getMetadata()).path;

      final source = FileSessionEventSource(
        env: env,
        resolvePath: (id) async => id == 'sess-a' ? path : null,
        // Zero interval: each poll round resolves as a microtask, so the
        // test drives the watch with pumpEventQueue instead of
        // wall-clock waits.
        pollInterval: Duration.zero,
      );
      final events = <AttachedSessionEvent>[];
      final sub = source.watch('sess-a').listen(events.add);
      // Backlog arrives on the first poll.
      await pumpEventQueue(times: 20);
      expect(events, hasLength(1));
      expect(events.last.appended.single.role, AttachedMessageRole.user);
      expect(events.last.appended.single.text, 'first question');

      // The owning process appends an assistant answer.
      await created.appendMessage(
        AssistantMessage(
          content: [TextContent(text: 'the answer')],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
      );
      await pumpEventQueue(times: 40);
      expect(events, hasLength(2));
      expect(events.last.appended.single.role, AttachedMessageRole.assistant);
      expect(events.last.appended.single.text, 'the answer');

      await sub.cancel();
      await source.dispose();
    });

    test(
      'input channel delivers user-kind mail the CLI inbox drains',
      () async {
        final channel = FileSessionInputChannel(repository: fabric);
        await channel.send('sess-a', 'typed in the app');

        final delivered = await fabric.peek('sess-a/main');
        expect(delivered, hasLength(1));
        expect(delivered.single.kind, AgentMessageKind.user);
        expect(delivered.single.text, 'typed in the app');
        expect(delivered.single.fromId, 'app');
        // Draining (what the CLI's steering poll does) consumes it.
        final drained = await fabric.drain('sess-a/main');
        expect(drained, hasLength(1));
        expect(await fabric.peek('sess-a/main'), isEmpty);
      },
    );
  });
}

// Coverage for attachedRowFromMessage branches (CRAP ratchet).
void _attachRowGroup() {
  group('attachedRowFromMessage', () {
    AssistantMessage assistant(List<ContentBlock> content) => AssistantMessage(
      content: content,
      api: 'test',
      provider: 'test',
      model: 'test-model',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026),
    );

    test('assistant with a tool call renders a tool row', () {
      final row = attachedRowFromMessage(
        assistant([const ToolCall(id: 'c1', name: 'bash', arguments: {})]),
      );
      expect(row?.role, AttachedMessageRole.tool);
      expect(row?.toolName, 'bash');
    });

    test('assistant with mixed text keeps the text', () {
      final row = attachedRowFromMessage(
        assistant([
          const ToolCall(id: 'c1', name: 'bash', arguments: {}),
          const TextContent(text: ' and text'),
        ]),
      );
      expect(row?.role, AttachedMessageRole.assistant);
      expect(row?.text, contains('and text'));
    });

    test('user with content blocks renders joined text', () {
      final row = attachedRowFromMessage(
        UserMessage(
          content: [
            const TextContent(text: 'hello '),
            const TextContent(text: 'world'),
          ],
          timestamp: DateTime.utc(2026),
        ),
      );
      expect(row?.text, 'hello world');
    });

    test('empty user content renders nothing', () {
      final row = attachedRowFromMessage(
        UserMessage(content: '', timestamp: DateTime.utc(2026)),
      );
      expect(row, isNull);
    });

    test('empty assistant content renders nothing', () {
      final row = attachedRowFromMessage(assistant(const []));
      expect(row, isNull);
    });
  });
}
