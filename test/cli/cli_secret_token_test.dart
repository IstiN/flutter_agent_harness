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

  group('formatTokenPreset', () {
    test('formats K values', () {
      expect(formatTokenPreset(4096), '4K');
      expect(formatTokenPreset(8192), '8K');
      expect(formatTokenPreset(16384), '16K');
      expect(formatTokenPreset(32768), '32K');
      expect(formatTokenPreset(65536), '64K');
    });

    test('formats M values', () {
      expect(formatTokenPreset(1048576), '1M');
      expect(formatTokenPreset(2097152), '2M');
    });

    test('leaves non-aligned values as raw numbers', () {
      expect(formatTokenPreset(500), '500');
      expect(formatTokenPreset(1000), '1000');
      expect(formatTokenPreset(2049), '2049');
    });

    test('round-trips with parseTokenPreset', () {
      for (final v in [4096, 8192, 16384, 65536, 1048576]) {
        expect(parseTokenPreset(formatTokenPreset(v)), v);
      }
    });
  });

  group('parseTokenPreset', () {
    test('parses K suffix', () {
      expect(parseTokenPreset('4K'), 4096);
      expect(parseTokenPreset('16K'), 16384);
    });

    test('parses M suffix', () {
      expect(parseTokenPreset('1M'), 1048576);
      expect(parseTokenPreset('2M'), 2097152);
    });

    test('parses bare numbers', () {
      expect(parseTokenPreset('12345'), 12345);
    });

    test('handles lowercase suffix', () {
      expect(parseTokenPreset('4k'), 4096);
      expect(parseTokenPreset('1m'), 1048576);
    });

    test('returns 0 for garbage', () {
      expect(parseTokenPreset('abc'), 0);
    });
  });

  group('extractDefaultValue', () {
    test('extracts (empty = X) hint', () {
      expect(extractDefaultValue('Enter name (empty = default):'), 'default');
      expect(extractDefaultValue('Size (empty=1024):'), '1024');
    });

    test('extracts (empty keeps \'X\') hint', () {
      expect(extractDefaultValue("Model (empty keeps 'gpt-4'):"), 'gpt-4');
    });

    test('returns null when no hint present', () {
      expect(extractDefaultValue('Enter value:'), isNull);
      expect(extractDefaultValue('Plain question'), isNull);
    });
  });

  group('_answerSecretRequest (line mode)', () {
    test('returns the entered value', () async {
      String? grantedName;
      String? grantedValue;
      final fake = FakeStreamFunction([
        // First turn: model calls request_secret.
        toolTurn([
          ToolCall(
            id: 'call_1',
            name: 'request_secret',
            arguments: {'name': 'MY_KEY', 'reason': 'need it'},
          ),
        ]),
        // Second turn: model acknowledges.
        textTurn('done'),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          onSecretGranted: (name, value) {
            grantedName = name;
            grantedValue = value;
          },
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();

      // Send a user message to trigger the model turn.
      io.sendLine('I need a key');

      // Wait for the secret prompt to appear, then send the value.
      await waitForIt(
        () => io.out.toString().contains('[secret] MY_KEY needed'),
      );
      io.sendLine('my-secret-value');

      await waitForIt(() => io.out.toString().contains('done'));
      io.sendLine('/exit');
      await run;

      expect(grantedName, 'MY_KEY');
      expect(grantedValue, 'my-secret-value');
    });

    test('returns null (declined) on empty input', () async {
      var granted = false;
      final fake = FakeStreamFunction([
        toolTurn([
          ToolCall(
            id: 'call_1',
            name: 'request_secret',
            arguments: {'name': 'API_KEY', 'reason': 'needed'},
          ),
        ]),
        textTurn('declined'),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          onSecretGranted: (_, _) => granted = true,
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();

      // Send a user message to trigger the model turn.
      io.sendLine('I need a key');

      await waitForIt(
        () => io.out.toString().contains('[secret] API_KEY needed'),
      );
      // Empty line = decline.
      io.sendLine('');

      await waitForIt(() => io.out.toString().contains('declined'));
      io.sendLine('/exit');
      await run;

      // The grant callback should NOT have been called.
      expect(granted, isFalse);
    });
  });
}
