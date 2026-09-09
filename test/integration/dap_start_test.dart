/// `/dap start` — the one-step local bring-up: generates a session master
/// secret when none is set, launches a local hub on the default port when
/// none answers, then connects (persisting the zero-config URL).
@Tags(['integration'])
library;

import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/hub/local_hub.dart';
import 'package:test/test.dart';

import '../../bin/fah_hub_plugin.dart';

class _CapturingIo implements PluginIO {
  final lines = <String>[];

  @override
  void write(String text) => lines.add(text);

  @override
  void writeln(String text) => lines.add(text);

  String get text => lines.join('\n');
}

void main() {
  late Directory tempHome;

  setUp(() async {
    tempHome = await Directory.systemTemp.createTemp('fah-dap-start-');
  });

  tearDown(() async {
    if (await tempHome.exists()) tempHome.deleteSync(recursive: true);
  });

  /// Finds a free loopback port (bind-close dance).
  Future<int> freePort() async {
    final probe = LocalHub(port: 0);
    await probe.start();
    final port = probe.url.port;
    await probe.stop();
    return port;
  }

  (SlashCommand, _CapturingIo, Map<String, String>) registerHost({
    required String localHubUrl,
    Future<bool> Function(int port)? healthProbe,
    Future<void> Function(int port)? hubSpawner,
    Map<String, String>? environment,
  }) {
    final env = environment ?? <String, String>{};
    final host = HubPluginHost(
      hub.HubPlugin(environment: env, home: tempHome.path),
      environment: env,
      home: tempHome.path,
      localHubUrl: localHubUrl,
      hubHealthProbe: healthProbe,
      hubSpawner: hubSpawner,
    );
    final io = _CapturingIo();
    final context = PluginContext(
      env: MemoryExecutionEnv(cwd: '/work'),
      io: io,
    );
    host.register(context);
    return (context.slashCommands['/dap']!, io, env);
  }

  test(
    'no secret + no hub: generates a secret, spawns a hub, connects',
    () async {
      final port = await freePort();
      final url = 'ws://127.0.0.1:$port/ws';
      LocalHub? spawned;
      var spawnCalls = 0;
      addTearDown(() async => spawned?.stop());

      Future<bool> probe(int p) async {
        try {
          final client = HttpClient()
            ..connectionTimeout = const Duration(milliseconds: 500);
          final response = await (await client.get('127.0.0.1', p, '/healthz'))
              .close();
          await response.drain<void>();
          client.close();
          return response.statusCode == 200;
        } on Object {
          return false;
        }
      }

      final (slash, io, env) = registerHost(
        localHubUrl: url,
        healthProbe: probe,
        hubSpawner: (p) async {
          spawnCalls++;
          spawned = LocalHub(port: p);
          await spawned!.start();
        },
      );

      await slash(['start']);

      expect(
        env[hub.envMasterSecret],
        isNotNull,
        reason: 'a session secret is generated when none is set',
      );
      expect(spawnCalls, 1, reason: 'the hub is spawned exactly once');
      expect(spawned, isNotNull);
      await spawned!.waitForHellos(1);
      expect(io.text, contains('DAP is up'));
      expect(io.text, contains('master secret'));
      // The zero-config URL is persisted for the next boot.
      final saved = File(
        '${tempHome.path}/.dap/config.json',
      ).readAsStringSync();
      expect(saved, contains(url));
    },
  );

  /// Points the boot-time connect at [url] so `/dap start` never races a
  /// dead default-hub dial (the production steady state after one start).
  void seedConfig(String url) {
    File('${tempHome.path}/.dap/config.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"url": "$url"}\n');
  }

  test('hub already answering: no spawn, still connects', () async {
    final running = LocalHub(port: 0);
    await running.start();
    addTearDown(running.stop);
    seedConfig(running.url.toString());
    var spawnCalls = 0;
    final (slash, io, _) = registerHost(
      localHubUrl: running.url.toString(),
      healthProbe: (p) async => true,
      hubSpawner: (p) async => spawnCalls++,
      environment: {hub.envMasterSecret: 'test-secret'},
    );
    await slash(['start']);
    expect(spawnCalls, 0);
    await running.waitForHellos(1);
    expect(io.text, contains('DAP is up'));
  });

  test('secret already set: no generation line', () async {
    final running = LocalHub(port: 0);
    await running.start();
    addTearDown(running.stop);
    seedConfig(running.url.toString());
    final (slash, io, env) = registerHost(
      localHubUrl: running.url.toString(),
      healthProbe: (p) async => true,
      hubSpawner: (p) async {},
      environment: {hub.envMasterSecret: 'test-secret'},
    );
    await slash(['start']);
    expect(env[hub.envMasterSecret], 'test-secret');
    expect(io.text, isNot(contains('generated')));
  });

  test('hub never comes up: honest error, no connect', () async {
    final port = await freePort();
    final (slash, io, _) = registerHost(
      localHubUrl: 'ws://127.0.0.1:$port/ws',
      healthProbe: (p) async => false,
      hubSpawner: (p) async {},
      environment: {hub.envMasterSecret: 'test-secret'},
    );
    await slash(['start']);
    expect(io.text, contains('did not come up'));
    expect(io.text, isNot(contains('DAP is up')));
  });

  test('read-only environment: friendly error instead of a crash', () async {
    final port = await freePort();
    final (slash, io, _) = registerHost(
      localHubUrl: 'ws://127.0.0.1:$port/ws',
      healthProbe: (p) async => true,
      hubSpawner: (p) async {},
      environment: const {},
    );
    await slash(['start']);
    expect(io.text, contains('read-only'));
  });

  test('a stale dead config does not block the one-step start', () async {
    // The live-incident shape: ~/.dap points at a dead port from an old
    // session, the boot reconnect loop churns against it, and /dap start
    // must still bring the agent online on the fresh hub.
    final deadPort = await freePort();
    seedConfig('ws://127.0.0.1:$deadPort/ws');
    final running = LocalHub(port: 0);
    await running.start();
    addTearDown(running.stop);
    final (slash, io, _) = registerHost(
      localHubUrl: running.url.toString(),
      healthProbe: (p) async => true,
      hubSpawner: (p) async {},
      environment: {hub.envMasterSecret: 'test-secret'},
    );
    await slash(['start']);
    expect(io.text, contains('DAP is up'));
    await running.waitForHellos(1);
    // …and the persisted config moved to the live hub.
    final saved = File(
      '${tempHome.path}/.dap/config.json',
    ).readAsStringSync();
    expect(saved, contains(running.url.toString()));
  });

  test('the /dap menu leads with the one-step start', () async {
    List<PluginMenuOption>? seenOptions;
    final env = <String, String>{};
    final host = HubPluginHost(
      hub.HubPlugin(environment: env, home: tempHome.path),
      environment: env,
      home: tempHome.path,
    );
    final context = PluginContext(
      env: MemoryExecutionEnv(cwd: '/work'),
      io: _CapturingIo(),
      pickOption: (title, options, {initialKey}) async {
        seenOptions = options;
        return null;
      },
    );
    host.register(context);
    await context.slashCommands['/dap']!([]);
    expect(seenOptions, isNotNull);
    expect(seenOptions!.first.$1, 'start');
    expect(seenOptions!.first.$3, isNotEmpty);
  });
}
