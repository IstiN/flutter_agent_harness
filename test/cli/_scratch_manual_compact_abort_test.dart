// Scratch probe v3: prompt first (transcript exists), then /compact + Ctrl+C.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

var calls = 0;

AssistantMessageEventStream stream(
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) {
  final n = ++calls;
  final stream = AssistantMessageEventStream();
  if (n == 1) {
    // A plain turn — settles fast, leaves a small transcript behind.
    for (final event in textTurn('done')) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
  // Every later call: the manual compaction summarizer — hangs until the
  // cancel token fires.
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
  test('probe v3: interrupt during manual /compact after a real turn',
      timeout: const Timeout(Duration(seconds: 90)), () async {
    const window32k = Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test-provider',
      baseUrl: 'https://example.test',
      contextWindow: 32768,
      maxTokens: 4096,
    );
    final env = MemoryExecutionEnv(cwd: '/work');
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final io = FakeCliIO();
    final cli = AgentCli(
      config: AgentCliConfig(
        model: window32k,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
        compactionEngine: CompactionEngine.classic,
      ),
      io: io,
      streamFunction: stream,
    );
    final run = cli.run();

    io.sendLine('go');
    await waitForIt(() => calls >= 1 && !cli.isBusy, reason: 'turn settled');
    // ignore: avoid_print
    print('PROBE: turn settled, calls=$calls — sending /compact');
    io.sendLine('/compact');
    await waitForIt(() => calls >= 2, reason: 'manual compaction started');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // ignore: avoid_print
    print('PROBE: interrupting now');
    io.interrupt();

    Object? runError;
    var runDone = false;
    final done = Completer<void>();
    run.then(
      (_) {
        runDone = true;
        done.complete();
      },
      onError: (Object e) {
        runError = e;
        runDone = true;
        done.complete();
      },
    );
    await done.future.timeout(const Duration(seconds: 8), onTimeout: () {
      // ignore: avoid_print
      print('PROBE: run() still alive 8s after interrupt');
      return;
    });
    // ignore: avoid_print
    print('PROBE: runDone=$runDone runError=$runError');
    // If still alive, is the REPL interactive? Try a second /compact: the
    // summarizer would go to call 3.
    if (!runDone) {
      io.sendLine('/compact');
      await Future<void>.delayed(const Duration(seconds: 3));
      // ignore: avoid_print
      print('PROBE: after second /compact, calls=$calls');
    }
    final out = io.out.toString();
    // ignore: avoid_print
    print('PROBE: output tail: ${out.substring(out.length > 1000 ? out.length - 1000 : 0)}');
  });
}
