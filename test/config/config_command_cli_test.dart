/// `fa config` verb dispatch (issue #29 S3): drives [runConfigServiceCommand]
/// end to end — exit codes and output per verb, plus the ConfigException
/// path — so the headless CLI entry stays covered.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

class _FakeCliIO implements CliIO {
  final out = StringBuffer();

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => out.write('$text\n');

  @override
  bool get isInteractive => false;

  @override
  bool get supportsRawMode => false;

  @override
  Stream<String> get lines => const Stream.empty();

  @override
  Stream<void> get interrupts => const Stream.empty();

  @override
  Stream<KeyEvent> get keys => const Stream<KeyEvent>.empty();
  @override
  int get columns => 80;

  @override
  int get rows => 24;
}

void main() {
  late MemoryExecutionEnv env;
  late _FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = _FakeCliIO();
  });

  Future<int> run(ConfigCliCommand cmd) =>
      runConfigServiceCommand(cmd, io: io, env: env, homeDir: '/home');

  test(
    'check exits 0 and prints the report when both files are absent',
    () async {
      expect(await run(const ConfigCliCommand(verb: 'check')), 0);
      expect(io.out.toString(), contains('config check: ok'));
    },
  );

  test('check exits 1 when a file is broken', () async {
    await env.writeFile('/home/.fah/config.yaml', 'mcp: [not, a, map]');
    expect(await run(const ConfigCliCommand(verb: 'check')), 1);
    expect(io.out.toString(), contains('config check: failed'));
  });

  test('path lists both locations', () async {
    expect(await run(const ConfigCliCommand(verb: 'path')), 0);
    expect(
      io.out.toString(),
      contains('global config: /home/.fah/config.yaml'),
    );
    expect(
      io.out.toString(),
      contains('project config: /work/.fah/config.yaml'),
    );
  });

  test('get found exits 0 and prints the value', () async {
    await env.writeFile('/home/.fah/config.yaml', 'provider: zai\n');
    expect(await run(const ConfigCliCommand(verb: 'get', key: 'provider')), 0);
    expect(io.out.toString(), contains('zai'));
  });

  test('get not-set exits 1 without throwing', () async {
    expect(await run(const ConfigCliCommand(verb: 'get', key: 'model')), 1);
    expect(io.out.toString(), contains('not set: model'));
  });

  test('get unknown key exits 1 with a named error', () async {
    expect(await run(const ConfigCliCommand(verb: 'get', key: 'nope')), 1);
    expect(io.out.toString(), contains('error:'));
  });

  test('set writes through and exits 0', () async {
    expect(
      await run(
        const ConfigCliCommand(verb: 'set', key: 'provider', value: 'zai'),
      ),
      0,
    );
    expect(io.out.toString(), contains('set provider = zai'));
    final get = await run(const ConfigCliCommand(verb: 'get', key: 'provider'));
    expect(get, 0);
    expect(io.out.toString(), contains('zai'));
  });
}
