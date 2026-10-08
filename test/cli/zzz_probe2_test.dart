import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _window = 32768;
const _reserve = 8192;

Model get _model => const Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: _window,
  maxTokens: 4096,
);

void main() {
  test('boot-scenario dump', timeout: const Timeout(Duration(minutes: 5)),
      () async {
    final io = FakeCliIO();
    final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName('boot-cap-target');
    for (var i = 0; i < 10; i++) {
      await seed.appendMessage(UserMessage.text('old$i ${'a' * 4000}'));
    }
    final firstKept = await seed.appendMessage(
      UserMessage.text('kept0 ${'a' * 4000}'),
    );
    await seed.appendCompaction(
      summary: 'earlier marathon context',
      firstKeptEntryId: firstKept,
      tokensBefore: 99999,
    );
    for (var i = 1; i < 40; i++) {
      await seed.appendMessage(UserMessage.text('kept$i ${'a' * 4000}'));
    }

    final calls = <int>[];
    final stream = FakeStreamFunction([
      textTurn('compacted boot summary'),
      textTurn('answered after boot cap'),
    ]);
    AssistantMessageEventStream wrapped(
      Model model,
      Context context, {
      CancelToken? cancelToken,
    }) {
      calls.add(context.messages.length);
      // ignore: avoid_print
      print('>>> call ${calls.length}: msgs=${context.messages.length} '
          'sys=${(context.systemPrompt ?? '').length}');
      return stream.call(model, context, cancelToken: cancelToken);
    }

    final agent = AgentCli(
      config: AgentCliConfig(
        model: _model,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        sessionName: 'boot-cap-target',
        homeDir: '/work',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
        compactionEngine: CompactionEngine.classic,
      ),
      io: io,
      streamFunction: wrapped,
    );

    final run = agent.run();
    var tries = 0;
    while (stream.calls < 1 && tries < 5000) {
      tries++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    io.sendLine('go');
    tries = 0;
    while (stream.calls < 2 && tries < 5000) {
      tries++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    io.sendLine('/exit');
    await run;
    // ignore: avoid_print
    print('=== io.out ===');
    final out = io.out.toString();
    // ignore: avoid_print
    print(out.replaceAll(RegExp(r'a{20,}'), 'aaaa…'));
    final log = (await env.readTextFile('/work/.fah/logs/fa.log')).getOrThrow();
    // ignore: avoid_print
    print('=== fa.log ===');
    // ignore: avoid_print
    print(log);
  });
}
