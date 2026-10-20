import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

final class _FlakyStore implements SecureKeyStore {
  Object? writeError;
  final map = <String, String>{};

  @override
  String get label => 'fake store';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String?> read(String name) async => map[name];

  @override
  Future<void> write(String name, String value) async {
    final error = writeError;
    if (error != null) throw error;
    map[name] = value;
  }

  @override
  Future<void> delete(String name) async => map.remove(name);
}

void main() {
  test('debug edit wizard', () async {
    final io = FakeCliIO();
    final fake = FakeStreamFunction([textTurn('ok')]);
    final store = _FlakyStore()
      ..writeError = StateError('keychain write failed (exit 45)');
    final cache = SecureKeyCache(store);
    await cache.probe();
    final registry = CustomProviderRegistry(const []);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: MemoryExecutionEnv(cwd: '/work'),
        sessionRoot: '/sessions',
        secureKeys: cache,
        customProviders: registry,
        modelsFetcher: (baseUrl, {required apiKey}) async => const [],
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: fake.call,
    );
    final run = cli.run();

    io.sendLine('/provider custom');
    for (var i = 0; i < 2000; i++) {
      if (io.out.toString().contains('type a number:')) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    io.sendLine('1');
    for (var i = 0; i < 2000; i++) {
      if (io.out.toString().contains('base URL (empty =')) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    io.sendLine('https://api.kimi.com/coding/v1');
    for (var i = 0; i < 2000; i++) {
      if (io.out.toString().contains('provider name (empty =')) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    io.sendLine('kimi_ira');
    for (var i = 0; i < 2000; i++) {
      if (io.out.toString().contains('API key (empty for none):')) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    io.sendLine('sk-ira-secret-789');
    for (var i = 0; i < 2000; i++) {
      if (io.out.toString().contains('no model list from the endpoint')) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    io.sendLine('proxy-model');
    for (var i = 0; i < 2000; i++) {
      if (io.out.toString().contains('switched provider to openai')) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // Let the flow's whenComplete run.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    stderr.writeln('--- after add wizard, flag='
        '${registry.find('kimi_ira')?.keyNotPersisted}');

    cli.startProviderEditWizardForTest(registry.find('kimi_ira'));
    var sawEdit = false;
    for (var i = 0; i < 2000; i++) {
      if (io.out.toString().contains('editing provider kimi_ira')) {
        sawEdit = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    stderr.writeln('--- saw editing banner: $sawEdit');
    Future<void> wait(String marker) async {
      for (var i = 0; i < 2000; i++) {
        if (io.out.toString().contains(marker)) return;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      stderr.writeln('--- STALLED waiting for: $marker');
      stderr.writeln('--- output tail:\n${io.out.toString()}');
    }

    await wait('type a number:');
    io.sendLine('1');
    await wait('base URL (empty = https://api.kimi.com/coding/v1');
    io.sendLine('');
    await wait('provider name (empty =');
    io.sendLine('');
    await wait('API key (empty for none):');
    io.sendLine('');
    await wait('model id (empty keeps');
    io.sendLine('');
    await wait('switched provider to openai');
    stderr.writeln('--- edit flow done; flag='
        '${registry.find('kimi_ira')?.keyNotPersisted}');

    io.sendLine('/exit');
    await run;
    io.close();
  }, timeout: const Timeout(Duration(seconds: 20)));
}
