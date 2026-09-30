// Scratch probe (round-6 verification): the two round-4/5 scenarios.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Scripted stream: plays `scripted[n-1]` unless `n >= hangFromCall`, in
/// which case it hangs until the cancel token fires (aborted error end).
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

const _tinyWindow = Model(
  id: 'tiny-window',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 12000,
  maxTokens: 4096,
);
const _wideWindow = Model(
  id: 'wide-window',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 32768,
  maxTokens: 4096,
);

late ExecutionEnv _sharedEnv;

AgentCliConfig _config(Model model, CompactionSettings settings) =>
    AgentCliConfig(
      model: model,
      apiKey: '[REDACTED:Sensitive Value]',
      env: _sharedEnv,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      compactionEngine: CompactionEngine.classic,
      compactionSettings: settings,
    );

Future<MemoryExecutionEnv> _work() async {
  final env = MemoryExecutionEnv(cwd: '/work');
  await env.writeFile('/work/.fah/memory/.last_maintenance', '');
  await env.writeFile('big.txt', List.filled(1000, 'x' * 45).join('\n'));
  return env;
}

void main() {
  test(
    'PROBE A: headless Ctrl+C during the FUNNEL compaction — no relaunch, loud abort',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      _sharedEnv = await _work();
  final env = _sharedEnv;
      final io = FakeCliIO();
      final fake = _ScriptedHang([
        toolTurn([
          const ToolCall(id: 't1', name: 'read', arguments: {'path': 'big.txt'}),
        ]),
        textTurn('summary pass one'),
        textTurn('summary pass two'),
      ], hangFromCall: 3);
      final cli = AgentCli(
        config: _config(
          _tinyWindow,
          const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 100000,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.runHeadless('count the words');
      await waitForIt(() => fake.calls >= 3, reason: 'funnel compaction started')
          .timeout(const Duration(seconds: 40), onTimeout: () {
        // ignore: avoid_print
        print('PROBE A DEBUG: calls=${fake.calls} (never reached 3)');
      });
      io.interrupt();
      final exitCode = await run.timeout(const Duration(seconds: 30));
      final output = io.out.toString();
      // ignore: avoid_print
      print('PROBE A: exit=$exitCode calls=${fake.calls} '
          'interrupted=${output.contains('interrupted by user')} '
          'verdict=${output.contains('The task was NOT continued')} '
          'relaunch=${fake.calls > 3}');
    },
  );

  test(
    'PROBE B: REPL Ctrl+C during a manual /compact — dim receipt, session alive',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      _sharedEnv = await _work();
  final env = _sharedEnv;
      final io = FakeCliIO();
      final fake = _ScriptedHang([
        toolTurn([
          const ToolCall(id: 't1', name: 'read', arguments: {'path': 'big.txt'}),
        ]),
        textTurn('first answer'),
        textTurn('resummarized context'),
        textTurn('second answer'),
      ], hangFromCall: 3);
      final cli = AgentCli(
        config: _config(
          _wideWindow,
          const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 2000,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();
      io.sendLine('go');
      await waitForIt(() => fake.calls >= 2 && !cli.isBusy, reason: 'turn 1 done');
      io.sendLine('/compact');
      await waitForIt(() => fake.calls >= 3, reason: 'manual compaction started');
      io.interrupt();
      await waitForIt(
        () => io.out.toString().contains('compaction interrupted'),
        reason: 'dim receipt printed',
      );
      fake.hangFromCall = 1 << 30; // the follow-up turn must play out
      io.sendLine('again');
      await waitForIt(() => fake.calls >= 4 && !cli.isBusy, reason: 'session alive');
      final output = io.out.toString();
      // ignore: avoid_print
      print('PROBE B: receipt=${output.contains('compaction interrupted')} '
          'secondAnswer=${output.contains('second answer')} '
          'errorLine=${output.contains("error:")}');
      io.sendLine('/exit');
      await run;
      await io.close();
    },
  );
}
