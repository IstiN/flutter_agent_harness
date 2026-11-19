// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2237 — zero-pass receipt honesty at the wrapper seam: an unforced
/// structured run that exits under-trigger reports the deciding gate (with
/// the basis/trigger numbers) through [AutoCompactorHooks.onDone], and the
/// compaction lane's zero provider calls stay observable.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

final Model _model = const Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'http://localhost:1',
  contextWindow: 800,
  maxTokens: 4096,
);

/// Window 800, reserve 200 -> trigger 600.
const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 200,
  keepRecentTokens: 200,
);

AssistantMessage _assistant(String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

final class _CapturingHooks implements AutoCompactorHooks {
  final doneCalls = <int>[];
  final doneReasons = <String?>[];

  @override
  void onDelta(String delta) {}

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}

  @override
  void onPass(AutoCompactorPass pass) {}

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onDone(int passes, int tokens, {String? reason}) {
    doneCalls.add(passes);
    doneReasons.add(reason);
  }

  @override
  void onBothRolesFailed(Object lastError) {}
}

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  test(
    'UT-4a/IT-2: an unforced under-trigger run reports the no-op reason '
    'through onDone with zero provider calls on the compaction lane',
    () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      await session.appendMessage(UserMessage.text('hi'));
      await session.appendMessage(_assistant('hello'));
      final state = AgentState(
        model: _model,
        messages: await session.buildContextMessages(),
      );

      var providerCalls = 0;
      final hooks = _CapturingHooks();

      final ok = await AutoCompactorFactory(
        session: session,
        state: state,
        window: 800,
        settings: _settings,
        sources: AutoCompactorSources(
          smolStream: null,
          smolModel: null,
          mainModel: _model,
          mainStream: (model, context, {cancelToken}) {
            providerCalls++;
            final stream = AssistantMessageEventStream();
            stream.end();
            return stream;
          },
        ),
        hooks: hooks,
      ).run();

      expect(ok, isTrue);
      // The zero-pass path must stay OBSERVABLE, not silent: zero
      // provider calls (the field loop's shape) with a reason-carrying
      // terminal receipt riding onDone.
      expect(providerCalls, 0, reason: 'no provider call may hide here');
      expect(hooks.doneCalls, [0]);
      final reason = hooks.doneReasons.single;
      expect(reason, isNotNull);
      expect(reason, contains('(trigger gate)'));
      expect(reason, contains('below trigger 600'));
    },
  );
}
