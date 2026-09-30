// Scratch probe: Ctrl+C during a manual `/compact` (line mode) — does the
// CancelledException from _runAutoCompact's rethrow kill the REPL loop?
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

AssistantMessageEventStream hangUntilCancelled(
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) {
  final stream = AssistantMessageEventStream();
  stream.push(StartEvent(partial: testAssistant()));
  cancelToken?.onCancel.then((_) {
    stream.push(
      ErrorEvent(
        reason: StopReason.aborted,
        error: testAssistant(
          stopReason: StopReason.aborted,
          errorMessage: 'Operation aborted',
        ),
      ),
    );
    stream.end();
  });
  return stream;
}

void main() {
  test('probe: interrupt during manual /compact', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    env.writeFile('big.txt', List.filled(500, 'x' * 45).join('\n'));
    final io = FakeCliIO();
    final cli = AgentCli(
      config: AgentCliConfig(
        model: const Model(
          id: 'test-model',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 32768,
          maxTokens: 4096,
        ),
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        compactionEngine: CompactionEngine.classic,
      ),
      io: io,
      streamFunction: hangUntilCancelled,
    );
    final run = cli.run();

    io.sendLine('/compact');
    await waitForIt(() => !cli.isBusy, reason: 'manual compaction started');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    io.interrupt();

    final crash = Completer<Object?>();
    final done = Completer<void>();
    run.then((_) => done.complete(), onError: (Object e) {
      crash.complete(e);
      done.complete();
    });
    await done.future.timeout(const Duration(seconds: 10), onTimeout: () {
      // ignore: avoid_print
      print('PROBE: run() still alive after interrupt (no crash)');
      return;
    });
    // ignore: avoid_print
    print('PROBE: run() completed with error: ${crash.isCompleted}');
    if (crash.isCompleted) {
      // ignore: avoid_print
      print('PROBE: error = ${await crash.future}');
    }
    // ignore: avoid_print
    print('PROBE: output tail: ${io.out.toString().substring(
      io.out.toString().length > 600 ? io.out.toString().length - 600 : 0,
    )}');
  });
}
