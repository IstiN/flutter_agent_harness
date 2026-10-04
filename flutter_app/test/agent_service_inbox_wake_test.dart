// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1180 review (thread 3): the app host's wake path must be receipted
/// like the CLI's — a refused wake is never a silent, unreceipted drop
/// (the second-host shape of the 2h04m blind window), and every real wake
/// leaves wake_attempted + turn_started rows. The refusal is also
/// surfaced through the app's never-silent log (AppLog), and the
/// wake_attempted receipt is deduped per refusal episode, not per 3s tick.
library;

import 'dart:convert';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/app_log.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

AssistantMessage _assistant(String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.now(),
);

StreamFunction _singleTurn(String text) => (model, context, {cancelToken}) {
  final stream = AssistantMessageEventStream()
    ..push(StartEvent(partial: _assistant('')))
    ..push(
      TextDeltaEvent(contentIndex: 0, delta: text, partial: _assistant(text)),
    )
    ..push(DoneEvent(reason: StopReason.stop, message: _assistant(text)));
  stream.end();
  return stream;
};

Future<void> _waitFor(
  bool Function() condition, {
  String reason = 'condition',
  Duration budget = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('timed out waiting: $reason');
}

Future<AgentService> _service(StreamFunction stream) => AgentService.create(
  config: AgentConfig(
    providerKind: 'openai-completions',
    modelId: 'test-model',
    baseUrl: 'https://example.test',
    apiKey: '[REDACTED:Sensitive Value]',
  ),
  env: MemoryExecutionEnv(cwd: '/work'),
  streamFunction: stream,
);

/// Sends one foreign agent-kind message to the service's main mailbox —
/// the shape a peer instance's `agent_message` produces.
Future<String> _sendForeignMail(AgentService service, String text) async {
  final sessionId = service.currentSessionId!;
  final message = AgentMessage(
    id: newMessageId(),
    fromId: 'peer-session/main',
    toId: '$sessionId/main',
    text: text,
    sentAt: DateTime.now().toUtc().toIso8601String(),
  );
  await FileMessagingRepository(
    env: service.env,
    root: '/work/sessions/--work--/messages',
  ).send(message);
  return message.id;
}

Future<List<Map<String, dynamic>>> _receipts(AgentService service) async {
  final text = (await service.env.readTextFile(
    '/work/sessions/--work--/messages/_scheduled/receipts.jsonl',
  )).valueOrNull;
  if (text == null || text.isEmpty) return const [];
  return [
    for (final line in text.trim().split('\n'))
      jsonDecode(line) as Map<String, dynamic>,
  ];
}

void main() {
  setUp(() {
    AppLog.reset();
    // The watcher starts during AgentService.create (initialize) — the
    // flag must be set before the service exists.
    AgentService.enableInboxWatcher = true;
  });
  tearDown(() => AgentService.enableInboxWatcher = false);

  test(
    'a refused wake on the app host is receipted (wake_attempted + '
    'wake_refused) and visible in the app log — never a silent drop',
    timeout: const Timeout(Duration(seconds: 90)),
    () async {
      final service = await _service(_singleTurn('noted'));
      addTearDown(service.dispose);
      // The session manager drives this in production: it allocates the
      // session id and starts the inbox watcher.
      await service.initialize();

      // Exhaust the chatter cap without user input (the seam; the CLI
      // REG test does the same).
      service.inboxWakeStreakForTest = 10;

      final mailId = await _sendForeignMail(service, 'ping from a peer');
      // Wait out several 3s watcher ticks of the SAME held batch: the
      // first tick announces, the rest must not duplicate the receipts.
      await _waitFor(
        () => AppLog.dump().contains('wake refused'),
        reason: 'the refusal is visible in the app log',
      );
      await Future<void>.delayed(const Duration(seconds: 7));
      expect(service.isStreaming, isFalse);
      expect(
        service.messages.where(
          (m) => m.role == 'user' && m.content.contains('inter-agent mail'),
        ),
        isEmpty,
        reason: 'a refused wake starts no turn',
      );

      final trail = await _receipts(service);
      final refused = trail
          .where((event) => event['event'] == 'wake_refused')
          .toList();
      expect(refused, hasLength(1), reason: 'one receipt per refusal episode');
      expect(refused.single['lane'], 'chatter');
      expect(refused.single['reason'], isNotEmpty);
      final attempted = trail
          .where((event) => event['event'] == 'wake_attempted')
          .toList();
      expect(
        attempted,
        hasLength(1),
        reason: 'deduped per episode — the held batch re-fires every 3s tick',
      );
      expect(
        (attempted.single['ids'] as List).cast<String>(),
        contains(mailId),
      );
    },
  );

  test(
    'an allowed wake on the app host leaves the full receipt trail '
    '(wake_attempted + turn_started)',
    timeout: const Timeout(Duration(seconds: 90)),
    () async {
      final service = await _service(_singleTurn('answering the peer'));
      addTearDown(service.dispose);
      await service.initialize();

      final mailId = await _sendForeignMail(service, 'hello from a peer');

      await _waitFor(
        () => service.messages.any(
          (m) => m.role == 'user' && m.content.contains('inter-agent mail'),
        ),
        reason: 'the wake starts a turn carrying the mail notice',
      );
      await service.waitForIdle();

      final trail = await _receipts(service);
      final byEvent = {
        for (final event in trail) event['event'] as String: event,
      };
      expect(byEvent['wake_attempted'], isNotNull);
      expect(
        (byEvent['wake_attempted']!['ids'] as List).cast<String>(),
        contains(mailId),
      );
      expect(byEvent['turn_started'], isNotNull);
    },
  );
}
