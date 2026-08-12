@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(StreamFunction streamFunction) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  group('line-mode key set prompt', () {
    test('/key set NAME (no value) prompts for value in line mode', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          secureKeys: cache,
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();

      io.sendLine('/key set MY_KEY');
      await waitForIt(() => io.out.toString().contains('value for MY_KEY:'));
      io.sendLine('secret-value');
      await waitForIt(() => io.out.toString().contains('saved MY_KEY'));
      io.sendLine('/exit');
      await run;

      expect(store.map['MY_KEY'], 'secret-value');
    });

    test('/key set NAME (no value) cancels on empty input', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          secureKeys: cache,
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();

      io.sendLine('/key set MY_KEY');
      await waitForIt(() => io.out.toString().contains('value for MY_KEY:'));
      io.sendLine('');
      await waitForIt(() => io.out.toString().contains('cancelled'));
      io.sendLine('/exit');
      await run;
    });
  });

  group('line-mode model-edit', () {
    test('/model-edit shows limits with no args in line mode', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/model-edit');
      await waitForIt(() => io.out.toString().contains('contextWindow'));
      io.sendLine('/exit');
      await run;
    });

    test('/model-edit contextWindow 128000 applies', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/model-edit contextWindow 128000');
      await waitForIt(
        () => io.out.toString().contains('model context window set to 128000'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('/model-edit maxTokens 8192 applies', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/model-edit maxTokens 8192');
      await waitForIt(
        () => io.out.toString().contains('model max tokens set to 8192'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('/model-edit bad field shows usage', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/model-edit badfield 100');
      await waitForIt(
        () => io.out.toString().contains(
          'usage: /model-edit <contextWindow|maxTokens> <n>',
        ),
      );
      io.sendLine('/exit');
      await run;
    });
  });

  group('formatTokenPreset', () {
    test('formats K, M, and raw', () {
      expect(formatTokenPreset(4096), '4K');
      expect(formatTokenPreset(1048576), '1M');
      expect(formatTokenPreset(500), '500');
    });
  });

  group('parseTokenPreset', () {
    test('parses K, M, and raw', () {
      expect(parseTokenPreset('4K'), 4096);
      expect(parseTokenPreset('1M'), 1048576);
      expect(parseTokenPreset('500'), 500);
    });
  });
}
