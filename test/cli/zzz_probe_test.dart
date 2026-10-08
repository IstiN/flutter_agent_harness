import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _window = 32768;
const _reserve = 8192;
final _threshold = _window - _reserve;

Model get _model => const Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: _window,
  maxTokens: 4096,
);

void main() {
  test('probe', timeout: const Timeout(Duration(minutes: 5)), () async {
    final io = FakeCliIO();
    final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final small = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await small.appendSessionName('small-boot');
    await small.appendMessage(UserMessage.text('tiny'));
    // Distinct creation timestamps: /resume lists sessions newest-first
    // and both ids would otherwise share the same millisecond.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final over = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await over.appendSessionName('boot-cap-target');
    for (var i = 0; i < 10; i++) {
      await over.appendMessage(UserMessage.text('old$i ${'a' * 4000}'));
    }
    final firstKept = await over.appendMessage(
      UserMessage.text('kept0 ${'a' * 4000}'),
    );
    await over.appendCompaction(
      summary: 'earlier marathon context',
      firstKeptEntryId: firstKept,
      tokensBefore: 99999,
    );
    for (var i = 1; i < 40; i++) {
      await over.appendMessage(UserMessage.text('kept$i ${'a' * 4000}'));
    }

    final cap = FakeStreamFunction([textTurn('compacted boot summary')]);
    final hang = AbortableStreamFunction();
    var hung = false;
    AssistantMessageEventStream streamCall(
      Model model,
      Context context, {
      CancelToken? cancelToken,
    }) {
      if (!hung) {
        hung = true;
        return hang.call(model, context, cancelToken: cancelToken);
      }
      return cap.call(model, context);
    }

    final agent = AgentCli(
      config: AgentCliConfig(
        model: _model,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        sessionName: 'small-boot',
        homeDir: '/work',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
        compactionEngine: CompactionEngine.classic,
      ),
      io: io,
      streamFunction: streamCall,
    );

    final run = agent.run();
    io.sendLine('go');
    var tries = 0;
    while (!agent.isBusy && tries < 5000) {
      tries++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    io.interrupt();
    tries = 0;
    while (agent.isBusy && tries < 5000) {
      tries++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // ignore: avoid_print
    print('=== after abort ===');
    // ignore: avoid_print
    print(io.out.toString());
    io.sendLine('/session boot-cap-target');
    tries = 0;
    while (cap.calls < 1 && tries < 5000) {
      tries++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // ignore: avoid_print
    print('=== after resume (cap.calls=${cap.calls}) ===');
    if (cap.contexts.isNotEmpty) {
      for (var i = 0; i < cap.contexts.length; i++) {
        final c = cap.contexts[i];
        // ignore: avoid_print
        print('--- cap call $i: sys=${c.systemPrompt?.length} msgs='
            '\\${c.messages.length}');
        for (final m in c.messages) {
          final t = m.toString();
          // ignore: avoid_print
          print('    msg: \\${t.length > 200 ? t.substring(0, 200) : t}');
        }
        final sp = c.systemPrompt ?? '';
        // ignore: avoid_print
        print('    sys: \\${sp.length > 300 ? sp.substring(0, 300) : sp}');
      }
    }
    // ignore: avoid_print
    print(io.out.toString());
    io.sendLine('/exit');
    await run;
    // ignore: avoid_print
    print('=== final (cap.calls=${cap.calls}) ===');
    try {
      final log = (await env.readTextFile('/work/.fah/logs/fa.log'))
          .getOrThrow();
      // ignore: avoid_print
      print('=== fa.log ===');
      // ignore: avoid_print
      print(log);
    } catch (e) {
      // ignore: avoid_print
      print('no fa.log: $e');
    }
    // ignore: avoid_print
    print(io.out.toString());
  });
}
