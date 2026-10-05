import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'agent_cli_test_support.dart';

void main() {
  test('debug empty path', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final io = FakeCliIO();
    addTearDown(io.close);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: FakeStreamFunction(const []).call,
      version: '0.0.0-test',
    );
    final run = cli.run();
    await waitForIt(() => !cli.isBusy, reason: 'boot');
    print('BOOTED, out so far: ${io.out.toString().length} chars');
    io.sendLine('/usage rebuild');
    await Future<void>.delayed(const Duration(seconds: 2));
    print('OUT: ---${io.out}---');
    io.sendLine('/exit');
    await Future<void>.delayed(const Duration(seconds: 2));
    print('after exit OUT: ---${io.out}---');
    await run.timeout(const Duration(seconds: 5));
  }, timeout: const Timeout(Duration(seconds: 20)));
}
