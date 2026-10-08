import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:yaml/yaml.dart';
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

  test('debug script 1', () async {
    await env.writeFile('/home/u/.fah/config.yaml', 'provider: openrouter\nmodel: m1\n');
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'k',
        env: env,
        homeDir: '/home/u',
        sessionRoot: '/sessions',
        modelsConfig: ModelsConfig(),
        modelsFetcher: (baseUrl, {required apiKey}) async => ['glm-5.3-flash'],
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );
    final run = cli.run();
    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('1');
    await waitForIt(() => io.out.toString().contains('provider'));
    io.sendLine('12');
    await waitForIt(() => io.out.toString().contains('model id (empty keeps'));
    io.sendLine('glm-5.3-flash');
    var capsReached = false;
    for (var i = 0; i < 2000; i++) {
      if (io.out.toString().contains('capabilities — zai/glm-5.3-flash')) {
        capsReached = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (!capsReached) {
      // ignore: avoid_print
      print('OUT1<<<${io.out.toString()}>>>');
      io.sendLine('/exit');
      await run;
      return;
    }
    io.sendLine('2');
    await waitForIt(() => io.out.toString().contains('maxTokens in tokens'));
    io.sendLine('65536');
    var wrote = false;
    for (var i = 0; i < 2000; i++) {
      if (io.out.toString().contains('models.overrides.zai.glm-5.3-flash')) {
        wrote = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (!wrote) {
      // ignore: avoid_print
      print('OUT2<<<${io.out.toString()}>>>');
      io.sendLine('/exit');
      await run;
      return;
    }
    print('FILE<<<${(await env.readTextFile('/home/u/.fah/config.yaml')).valueOrNull}>>>');
    io.sendLine('/exit');
    await run;
    await flow;
  });
}
