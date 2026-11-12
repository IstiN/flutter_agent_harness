// gh-2097 — compaction diagnostic log honesty: every compaction pass
// log line names its session (`sid=`), and the diagnostic appends are
// buffered through one serialized chain that exit paths drain, so a
// burst of lines lands complete and in order instead of being dropped
// by unawaited fire-and-forget appends racing the process exit.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _window = 100000;

Model get _model => const Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: _window,
  maxTokens: 4096,
);

const _taskMarker = 'diag log compaction probe';

/// A structured-compaction-aware fake stream: judge calls (the
/// context-hygiene judge prompt) answer `[]` (hide nothing), checkpoint
/// calls answer a canned summary, real turns answer from [turnAnswers].
final class _CompactionAwareStream {
  final turnAnswers = <String>[];
  final contexts = <Context>[];
  var _answered = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final prompt = [
      for (final m in context.messages)
        switch (m) {
          UserMessage() => messageText(m),
          AssistantMessage() =>
            m.content.whereType<TextContent>().map((b) => b.text).join(),
          _ => '',
        },
    ].join('\n');
    final String reply;
    if (prompt.contains('context-hygiene judge')) {
      reply = '[]';
    } else if (prompt.contains('Write a checkpoint')) {
      reply = 'DIAG CHECKPOINT: the probe task summary.';
    } else {
      reply = turnAnswers[_answered++ % turnAnswers.length];
    }
    final stream = AssistantMessageEventStream();
    for (final event in textTurn(reply)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

AgentCli _cli(
  MemoryExecutionEnv env,
  FakeCliIO io,
  _CompactionAwareStream stream,
) => AgentCli(
  config: AgentCliConfig(
    model: _model,
    apiKey: '[REDACTED:Sensitive-Value]',
    env: env,
    sessionRoot: '/sessions',
    sessionName: 'diag-log-compaction-target',
    homeDir: '/home',
    providerKind: 'openai-completions',
    skillsAccess: SkillsAccess.granted,
  ),
  io: io,
  environment: const {'FAH_COMPACT_TRIGGER_TOKENS': '800'},
  streamFunction: stream.call,
);

Future<MemoryExecutionEnv> _seed(String name) async {
  final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
  // Suppress session-start memory maintenance (suite pattern).
  await env.writeFile('/work/.fah/memory/.last_maintenance', '');
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final seed = await repo.create(
    JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
  );
  await seed.appendSessionName(name);
  await seed.appendMessage(UserMessage.text('TASK $_taskMarker ${'t ' * 200}'));
  for (var i = 0; i < 40; i++) {
    await seed.appendMessage(UserMessage.text('filler$i ${'x' * 1000}'));
  }
  return env;
}

/// [waitForIt] with a LAZY description: the failure text is built at
/// timeout, so it names the state that actually was reached.
Future<void> waitUntil(
  bool Function() condition,
  String Function() describe,
) async {
  for (var i = 0; i < 5000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${describe()}');
}

void main() {
  test(
    'every auto-compact diagnostic line names its session (sid)',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final io = FakeCliIO();
      final env = await _seed('diag-log-compaction-target');
      final stream = _CompactionAwareStream()..turnAnswers.addAll(['ok']);
      final agent = _cli(env, io, stream);
      final run = agent.run();
      io.sendLine('go');
      await waitUntil(
        () =>
            stream.contexts.isNotEmpty &&
            stream.contexts.any(
              (c) => (c.systemPrompt ?? '').startsWith('You are Fa'),
            ) &&
            !agent.isBusy,
        () => 'turn 1: calls=${stream.contexts.length}',
      );
      io.sendLine('/exit');
      await run;

      final log = (await env.readTextFile(
        '/home/.fah/logs/fa.log',
      )).valueOrNull;
      expect(log, isNotNull);
      final compactLines = log!
          .split('\n')
          .where((line) => line.contains('auto-compact'))
          .toList();
      expect(compactLines, isNotEmpty, reason: 'the fixture must compact');
      expect(
        compactLines.where((line) => line.contains('auto-compact pass')),
        isNotEmpty,
        reason: 'the fixture must run at least one compaction pass',
      );
      expect(
        compactLines.where((line) => line.contains('auto-compact done')),
        isNotEmpty,
        reason: 'the fixture must close the run bracket',
      );
      for (final line in compactLines) {
        expect(
          line,
          contains(RegExp(r'sid=[0-9a-f]{8}')),
          reason: 'compaction line without a session id: $line',
        );
      }
    },
  );

  test(
    'a diagnostic burst lands complete and in order (no dropped lines)',
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final cli = AgentCli(
        config: AgentCliConfig(
          model: _model,
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          homeDir: '/home',
          providerKind: 'openai-completions',
        ),
        io: FakeCliIO(),
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
      for (var i = 0; i < 50; i++) {
        cli.logDiagnosticForTest('burst line $i of 50');
      }
      await cli.flushDiagnosticLog();

      final log = (await env.readTextFile(
        '/home/.fah/logs/fa.log',
      )).valueOrNull;
      expect(log, isNotNull);
      final indexes = [
        for (var i = 0; i < 50; i++)
          () {
            final needle = 'burst line $i of 50';
            final index = log!.indexOf(needle);
            expect(index, greaterThanOrEqualTo(0), reason: 'missing: $needle');
            return index;
          }(),
      ];
      final sorted = [...indexes]..sort();
      expect(
        indexes,
        sorted,
        reason:
            'the burst must land in emission order — no drops, no '
            'interleaved partial writes',
      );
    },
  );
}
