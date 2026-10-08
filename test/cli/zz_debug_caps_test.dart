import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void _p(String tag, String body) => print('$tag<<<$body>>>');

Future<bool> _poll(FutureOr<bool> Function() condition) async {
  for (var i = 0; i < 4000; i++) {
    if (await condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return false;
}

String _tail() {
  final out = io.out.toString();
  return out.substring(out.length - 2000 < 0 ? 0 : out.length - 2000);
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
    if (!await _poll(() => io.out.toString().contains('model capabilities'))) {
      _p('F0', _tail()); return;
    }
    io.sendLine('1');
    if (!await _poll(() => io.out.toString().contains('— provider'))) {
      _p('F1', _tail()); return;
    }
    io.sendLine('12');
    if (!await _poll(() => io.out.toString().contains('model id (empty keeps'))) {
      _p('F2', _tail()); return;
    }
    io.sendLine('glm-5.3-flash');
    if (!await _poll(() => io.out.toString().contains('capabilities — zai/glm-5.3-flash'))) {
      _p('F3', _tail()); return;
    }
    io.sendLine('2');
    if (!await _poll(() => io.out.toString().contains('maxTokens in tokens'))) {
      _p('F4', _tail()); return;
    }
    io.sendLine('65536');
    if (!await _poll(() => io.out.toString().contains('models.overrides.zai.glm-5.3-flash'))) {
      _p('F5', _tail()); return;
    }
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
    try {
      await flow.timeout(const Duration(seconds: 15));
      print('FLOWDONE<<<');
    } catch (e) {
      print('FLOWHANG<<<${_tail()}>>>');
      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 10));
      return;
    }
    io.sendLine('/exit');
    await run;
    // ignore: avoid_print
    print(
      'DONE<<<${(await env.readTextFile('/home/u/.fah/config.yaml')).valueOrNull}>>>',
    );
  });
}
