import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

Future<bool> _poll(FutureOr<bool> Function() condition) async {
  for (var i = 0; i < 4000; i++) {
    if (await condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return false;
}

String _tail() {
  final out = io.out.toString();
  return out.substring(out.length - 600 < 0 ? 0 : out.length - 600);
}

late MemoryExecutionEnv env;
late FakeCliIO io;

void main() {
  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  test('debug 1', () async {
    await env.writeFile(
      '/home/u/.fah/config.yaml',
      'provider: openrouter\nmodel: m1\n',
    );
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'k',
        env: env,
        homeDir: '/home/u',
        sessionRoot: '/sessions',
        modelsConfig: ModelsConfig(),
        modelsFetcher: (baseUrl, {required apiKey}) async => [
          'glm-5.3-flash',
        ],
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );
    final run = cli.run();
    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('1');
    // ignore: avoid_print
    print('S1<<<${_tail()}>>>');
    await waitForIt(() => io.out.toString().contains('provider'));
    io.sendLine('12');
    // ignore: avoid_print
    print('S2<<<${_tail()}>>>');
    await waitForIt(
      () => io.out.toString().contains('model id (empty keeps'),
    );
    io.sendLine('glm-5.3-flash');
    // ignore: avoid_print
    print('S3<<<${_tail()}>>>');
    await waitForIt(
      () => io.out.toString().contains('capabilities — zai/glm-5.3-flash'),
    );
    io.sendLine('2');
    await waitForIt(
      () => io.out.toString().contains('maxTokens in tokens'),
    );
    io.sendLine('65536');
    await waitForIt(
      () => io.out.toString().contains('models.overrides.zai.glm-5.3-flash'),
    );
    io.sendLine('3');
    if (!await _poll(
      () => io.out.toString().contains('thinking level'),
    )) {
      // ignore: avoid_print
      print('OUT3<<<tail: ${_tail()}>>>');
    }
    io.sendLine('5');
    if (!await _poll(
      () => io.out.toString().contains('thinkingLevel = high'),
    )) {
      // ignore: avoid_print
      print('OUT4<<<tail: ${_tail()}>>>');
    }
    io.sendLine('5');
    if (!await _poll(() => io.out.toString().contains('Pin or edit'))) {
      // ignore: avoid_print
      print('OUT5<<<tail: ${_tail()}>>>');
    }
    io.sendLine('3');
    await flow;
    io.sendLine('/exit');
    await run;
    // ignore: avoid_print
    print(
      'DONE<<<${(await env.readTextFile('/home/u/.fah/config.yaml')).valueOrNull}>>>',
    );
  });
}
