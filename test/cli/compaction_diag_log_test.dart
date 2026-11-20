// gh-2097 — compaction diagnostic log honesty: every compaction pass
// log line names its session (`sid=`), and the diagnostic appends are
// buffered through one serialized chain that exit paths drain, so a
// burst of lines lands complete and in order instead of being dropped
// by unawaited fire-and-forget appends racing the process exit.
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
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

/// Best-effort teardown of the systemTemp artifact dir. The headless run's
/// exit drains the diag-log chain before the seal (gh-2097), but the seal
/// itself documents tolerated straggler writes after it (a late settle's
/// registry snapshot, a lost usage record) — one can land in the tree a
/// beat after the test body finished asserting, and a recursive delete
/// that listed the tree before that write throws errno 39 (ENOTEMPTY,
/// issue #2352, 2/2 same-sig). Retry briefly, then abandon the dir (same
/// convention as agent_cli_single_render_test / settings_flow_test): the
/// dir is a disposable systemTemp artifact holding nothing the test still
/// reads once the body returned, and a leaked temp dir must never fail a
/// green run.
Future<void> _deleteBestEffort(Directory dir) async {
  for (var attempt = 1; ; attempt++) {
    try {
      await dir.delete(recursive: true);
      return;
    } on FileSystemException catch (error) {
      if (attempt >= 3) {
        print('teardown left ${dir.path} behind: $error');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

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
    '#2274 AC1: a latched judge skip renders as a non-failure line — '
    'no FAILED pass for the designed skip',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final taskDir = await Directory.systemTemp.createTemp('fa_2274_skip');
      addTearDown(() => _deleteBestEffort(taskDir));
      final home = '${taskDir.path}/home';
      // Content-routed fake: the hide judge (the `context-hygiene judge`
      // system prompt) answers garbage — two unparseable answers engage
      // the cross-run latch (gh-2096) — and the checkpoint summarizer
      // answers its canned text. Real turns run EIGHT bash tool rounds
      // (two calls each): every round lands hideable tool-call pairs
      // past the protected tail, so the relief compactions first pay
      // the judge ladder honestly (and latch), then — judge
      // healthy-latched — take the designed skip.
      final realTurns = <List<AssistantMessageEvent>>[
        for (var round = 0; round < 8; round++)
          toolTurn([
            ToolCall(
              id: 'c${round}a',
              name: 'bash',
              arguments: {'command': 'seq 1 2000'},
            ),
            ToolCall(
              id: 'c${round}b',
              name: 'bash',
              arguments: {'command': 'seq 1 2000'},
            ),
          ]),
        textTurn('all reads done'),
      ];
      AssistantMessageEventStream routed(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        final system = context.systemPrompt ?? '';
        String? reply;
        if (system.contains('context-hygiene judge')) {
          reply = 'the judge endpoint is speaking gibberish, not json';
        } else if (system.contains('Write a checkpoint')) {
          reply = 'DIAG CHECKPOINT: the probe task summary.';
        }
        final List<AssistantMessageEvent> events;
        if (reply != null) {
          events = textTurn(reply);
        } else if (realTurns.isNotEmpty) {
          events = realTurns.removeAt(0);
        } else {
          // An unscripted LM call (a residual summarizer): answer with a
          // canned summary so the run still settles.
          events = textTurn('FA-2274 fallback summary.');
        }
        final stream = AssistantMessageEventStream();
        for (final event in events) {
          stream.push(event);
        }
        stream.end();
        return stream;
      }

      final cli = AgentCli(
        config: AgentCliConfig(
          model: _model,
          apiKey: '[REDACTED:Sensitive-Value]',
          env: LocalExecutionEnv(cwd: taskDir.path),
          sessionRoot: '${taskDir.path}/sessions',
          homeDir: home,
          providerKind: 'openai-completions',
          approvalMode: ApprovalMode.yolo,
        ),
        io: FakeCliIO(),
        environment: const {'FAH_COMPACT_TRIGGER_TOKENS': '800'},
        streamFunction: routed,
      );
      final exit = await cli.runHeadless('read two big files');
      expect(exit, 0, reason: 'the headless run must complete cleanly');

      final log = await File('$home/.fah/logs/fa.log').readAsString();
      final compactLines = log
          .split('\n')
          .where((line) => line.contains('auto-compact'))
          .toList();
      expect(compactLines, isNotEmpty, reason: 'the fixture must compact');
      // The latch engaged organically: an honest judge failure (the
      // garbage endpoint) rendered FAILED before any skip existed.
      expect(
        compactLines.any(
          (line) => line.contains('FAILED') && line.contains('unparseable'),
        ),
        isTrue,
        reason:
            'the judge failures that engage the latch are real '
            'failures and must keep rendering as FAILED: '
            '${compactLines.join(" | ")}',
      );
      // AC1: the designed skip renders as a NON-FAILURE line. Its
      // diagnostic line carries the reason, but never the FAILED verdict.
      final skipLines = compactLines
          .where((line) => line.contains('judge-latch skip'))
          .toList();
      expect(
        skipLines,
        isNotEmpty,
        reason:
            'the latch must skip the judge on a later hide-ladder '
            'pass: ${compactLines.join(" | ")}',
      );
      for (final line in skipLines) {
        expect(
          line.contains('FAILED'),
          isFalse,
          reason:
              'a designed judge-latch skip must never log as FAILED: '
              '$line',
        );
        expect(line, contains('sid='), reason: 'gh-2097 invariant kept');
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
