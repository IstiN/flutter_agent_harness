// Scratch probe (round-3): Ctrl+C during a HEADLESS funnel compaction.
// Prediction: isBusy is false (no _startRun in headless) -> the interrupt
// takes the compaction-ONLY branch -> no sticky flag -> _maybeAutoCompact
// swallows the cancel -> the funnel RETRIES (fresh compaction after the
// user's stop) and lands the false "NOT continued" verdict.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Copy of the retry test's scripted stream (defined in that test file).
class _ScriptedHang {
  _ScriptedHang(this.scripted, {this.hangFromCall = 1 << 30});
  final List<List<AssistantMessageEvent>> scripted;
  var calls = 0;
  int hangFromCall;
  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final n = ++calls;
    final stream = AssistantMessageEventStream();
    if (n < hangFromCall || n > scripted.length) {
      for (final event in scripted[n - 1]) {
        stream.push(event);
      }
      stream.end();
      return stream;
    }
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
}


void main() {
  test('probe: interrupt during HEADLESS funnel compaction',
      timeout: const Timeout(Duration(seconds: 120)), () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    env.writeFile('big.txt', List.filled(1000, 'x' * 45).join('\n'));
    final io = FakeCliIO();
    final fake = _ScriptedHang([
      toolTurn([
        const ToolCall(id: 't1', name: 'read', arguments: {'path': 'big.txt'}),
      ]),
      textTurn('summary pass one'),
      textTurn('summary pass two'), // consumed by funnel attempt 2
      textTurn('summary pass three'),
    ], hangFromCall: 3);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: const Model(
          id: 'tiny-window',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 12000,
          maxTokens: 4096,
        ),
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        compactionEngine: CompactionEngine.classic,
        compactionSettings: const CompactionSettings(
          enabled: true,
          reserveTokens: 100,
          keepRecentTokens: 100000,
        ),
      ),
      io: io,
      streamFunction: fake.call,
    );

    final run = cli.runHeadless('count the words');
    // Wait until the funnel's compaction summarizer (call 3) is hanging.
    await waitForIt(() => fake.calls >= 3, reason: 'funnel compaction started');
    io.interrupt();
    // Re-arm IMMEDIATELY: the funnel loop relaunches attempt 2 within
    // microtasks of the swallow, before the receipt is even printed.
    fake.hangFromCall = 1 << 30;
    await waitForIt(
      () => io.out.toString().contains('compaction interrupted'),
      reason: 'the compaction-only receipt printed',
    );
    final exitCode = await run.timeout(const Duration(seconds: 60));
    final output = io.out.toString();
    // ignore: avoid_print
    print('PROBE: exitCode=$exitCode calls=${fake.calls}');
    // ignore: avoid_print
    print('PROBE: verdict=${output.contains('The task was NOT continued')} '
        'resuming=${output.contains('[resuming]')}');
    // ignore: avoid_print
    print('PROBE: tail=${output.substring(
      output.length > 500 ? output.length - 500 : 0,
    )}');
  });
}
