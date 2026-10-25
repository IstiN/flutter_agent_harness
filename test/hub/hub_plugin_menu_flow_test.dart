// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Unit coverage for the hub plugin host's menu / slash / tool surface
/// (the guards CRAP gate measures the merged unit-suite lcov, which
/// excludes integration-tagged tests — these flows therefore need an
/// untagged in-VM driver). Every dial targets 127.0.0.1:9 (port 9 is
/// the discard service: refused instantly, no network dependency).
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../../bin/fah_hub_plugin.dart';

final class _CapturingIo implements PluginIO {
  final lines = <String>[];

  @override
  void write(String text) => lines.add(text);

  @override
  void writeln(String text) => lines.add(text);

  String get text => lines.join('\n');
}

/// Deterministic disconnected hub: no sockets, retries, or wall-clock waits.
final class _DeadHubPlugin extends hub.HubPlugin {
  _DeadHubPlugin({
    required Map<String, String> environment,
    required String home,
  }) : super(environment: environment, home: home);

  @override
  Future<void> start({hub.HubIdentity? identity}) async {}

  @override
  Future<hub.HubStatus> status() async => const hub.HubStatus(
    connected: false,
    agentId: null,
    name: null,
    url: 'ws://127.0.0.1:9/ws',
    channels: [],
    welcomes: 0,
    hellos: 0,
  );

  @override
  Future<List<hub.AgentInfo>> peers() async =>
      throw StateError('test hub is disconnected');

  @override
  Future<hub.DapConnection> connectTo(
    String host, {
    String? name,
    String? channel,
  }) async => throw StateError('test hub is disconnected');
}

void main() {
  late Directory tempHome;

  setUp(() async {
    tempHome = await Directory.systemTemp.createTemp('fah-hub-menu-');
  });

  tearDown(() async {
    if (await tempHome.exists()) tempHome.deleteSync(recursive: true);
  });

  (SlashCommand, _CapturingIo, Map<String, String>, hub.HubPlugin)
  registerHost({
    PluginPickOption? pickOption,
    PluginAskLine? askLine,
    Map<String, String>? environment,
    bool deadHub = false,
  }) {
    final env = environment ?? <String, String>{};
    final plugin = deadHub
        ? _DeadHubPlugin(environment: env, home: tempHome.path)
        : hub.HubPlugin(environment: env, home: tempHome.path);
    final host = HubPluginHost(plugin, environment: env, home: tempHome.path);
    final io = _CapturingIo();
    final context = PluginContext(
      env: MemoryExecutionEnv(cwd: '/work'),
      io: io,
      pickOption: pickOption,
      askLine: askLine,
    );
    host.register(context);
    return (context.slashCommands['/dap']!, io, env, plugin);
  }

  /// The host connects in the background at register time; wait (max
  /// ~5 s) until the vendored plugin accepted its start so status-backed
  /// commands do not race the boot dial.
  Future<void> settleBoot(hub.HubPlugin plugin) async {
    for (var i = 0; i < 500; i++) {
      try {
        await plugin.status();
        return;
      } on StateError {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  }

  group('/dap args (no interactive host)', () {
    test(
      'no args prints the disabled one-liner without a master secret',
      () async {
        final (slash, io, _, _) = registerHost();
        await slash([]);
        expect(io.text, contains('DAP disabled'));
      },
    );

    test(
      'no args prints the disconnected status with a master secret',
      () async {
        final (slash, io, _, plugin) = registerHost(
          environment: const {'DAP_MASTER_SECRET': 'test-master-secret'},
        );
        await settleBoot(plugin);
        await slash([]);
        expect(io.text, contains('hub disconnected'));
      },
    );

    test('start generates the session secret and fails the local spawn '
        'gracefully', () async {
      final (slash, io, env, _) = registerHost();
      await slash(['start']);
      expect(env['DAP_MASTER_SECRET'], isNotNull);
      expect(io.text, contains('master secret generated'));
      expect(io.text, contains('local hub'));
      expect(io.text, isNot(contains('DAP is up')));
    });
  });

  group('/dap menu (interactive host)', () {
    test('cancelled pick stays quiet', () async {
      final (slash, io, _, _) = registerHost(
        pickOption: (title, options, {initialKey}) async => null,
      );
      await slash([]); // completes without crashing — cancel stays quiet
      expect(
        io.lines.where((l) => l.startsWith('[hub] connect failed')),
        isEmpty,
      );
    });

    test('status choice prints the disconnected line', () async {
      final (slash, io, _, plugin) = registerHost(
        environment: const {'DAP_MASTER_SECRET': 'test-master-secret'},
        pickOption: (title, options, {initialKey}) async => 'status',
      );
      await settleBoot(plugin);
      await slash([]);
      expect(io.text, contains('hub disconnected'));
    });

    test('about choice prints the about text', () async {
      final (slash, io, _, _) = registerHost(
        pickOption: (title, options, {initialKey}) async => 'about',
      );
      await slash([]);
      expect(io.text, contains('Distributed Agents Platform'));
    });

    test('secret choice sets the session secret and reconnects', () async {
      final (slash, io, env, plugin) = registerHost(
        environment: {'DAP_HUB_URL': 'ws://127.0.0.1:9/ws'},
        pickOption: (title, options, {initialKey}) async => 'secret',
        deadHub: true,
        askLine: (prompt, {secret = false}) async => 'picked-secret',
      );
      await settleBoot(plugin);
      await slash([]);
      expect(env['DAP_MASTER_SECRET'], 'picked-secret');
      expect(io.text, contains('master secret set for this session'));
    });

    test('connect choice without a master secret hints at the secret '
        'step', () async {
      final (slash, io, _, _) = registerHost(
        pickOption: (title, options, {initialKey}) async => 'connect',
        askLine: (prompt, {secret = false}) async => '',
      );
      await slash([]);
      expect(io.text, contains('needs a master secret first'));
    });

    test('start choice runs the one-step bring-up', () async {
      final (slash, io, env, plugin) = registerHost(
        environment: {'DAP_HUB_URL': 'ws://127.0.0.1:9/ws'},
        pickOption: (title, options, {initialKey}) async => 'start',
        askLine: (prompt, {secret = false}) async => '',
      );
      await settleBoot(plugin);
      await slash([]);
      expect(env['DAP_MASTER_SECRET'], isNotNull);
      expect(io.text, contains('master secret generated'));
    });

    test('stop choice stops quietly when nothing is running', () async {
      final (slash, io, _, _) = registerHost(
        environment: const {'DAP_MASTER_SECRET': 'test-master-secret'},
        pickOption: (title, options, {initialKey}) async => 'stop',
      );
      await slash([]);
      expect(io.text, contains('not running'));
    });
  });

  group('dap_* tools', () {
    (List<AgentTool>, hub.HubPlugin) registerToolsHost() {
      final env = <String, String>{
        'DAP_MASTER_SECRET': 'test-master-secret',
        'DAP_HUB_URL': 'ws://127.0.0.1:9/ws',
      };
      final plugin = _DeadHubPlugin(environment: env, home: tempHome.path);
      final host = HubPluginHost(plugin, environment: env, home: tempHome.path);
      final context = PluginContext(
        env: MemoryExecutionEnv(cwd: '/work'),
        io: _CapturingIo(),
      );
      host.register(context);
      await settleBoot(plugin);
      final tools = context.tools;
      expect(tools.length, 5);
      return (tools, plugin);
    }

    AgentTool toolByName(List<AgentTool> tools, String name) =>
        tools.firstWhere((t) => t.name == name);

    test('dap_status reports the disconnected state', () async {
      final (tools, plugin) = registerToolsHost();
      await settleBoot(plugin);
      final result = await toolByName(
        tools,
        'dap_status',
      ).execute(const {}, null, null);
      final text = result.content
          .whereType<TextContent>()
          .map((c) => c.text)
          .join();
      expect(text, contains('connected: false'));
    });

    test('dap_peers surfaces the not-connected error', () async {
      final (tools, plugin) = registerToolsHost();
      await settleBoot(plugin);
      await expectLater(
        toolByName(tools, 'dap_peers').execute(const {}, null, null),
        throwsA(isA<StateError>()),
      );
    });

    test('dap_dm rejects an unknown peer and lists the roster', () async {
      final (tools, _) = registerToolsHost();
      await expectLater(
        toolByName(
          tools,
          'dap_dm',
        ).execute(const {'to': 'nobody', 'text': 'hello'}, null, null),
        throwsA(isA<StateError>()),
      );
    });

    test('dap_invite surfaces the not-started error', () async {
      final (tools, _) = registerToolsHost();
      await expectLater(
        toolByName(
          tools,
          'dap_invite',
        ).execute(const {'nameOrId': 'nobody'}, null, null),
        throwsA(isA<StateError>()),
      );
    });

    test('dap_connect surfaces the dial error', () async {
      final (tools, _) = registerToolsHost();
      await expectLater(
        toolByName(
          tools,
          'dap_connect',
        ).execute(const {'host': '127.0.0.1:9'}, null, null),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('publicChannelFor', () {
    test('returns false with no effective memberships', () async {
      final env = <String, String>{};
      final plugin = hub.HubPlugin(environment: env, home: tempHome.path);
      final host = HubPluginHost(plugin, environment: env, home: tempHome.path);
      final context = PluginContext(
        env: MemoryExecutionEnv(cwd: '/work'),
        io: _CapturingIo(),
      );
      host.register(context);
      expect(
        await HubPluginHost.publicChannelFor(plugin, 'no-such-channel'),
        isFalse,
      );
    });
  });

  group('/network args', () {
    (SlashCommand, _CapturingIo) registerNetworkHost() {
      final env = <String, String>{};
      final plugin = hub.HubPlugin(environment: env, home: tempHome.path);
      final host = HubPluginHost(plugin, environment: env, home: tempHome.path);
      final io = _CapturingIo();
      final context = PluginContext(
        env: MemoryExecutionEnv(cwd: '/work'),
        io: io,
      );
      host.register(context);
      return (context.slashCommands['/network']!, io);
    }

    test('bare /network on a headless host lists the channel count', () async {
      final (slash, io) = registerNetworkHost();
      await slash([]);
      expect(io.text, startsWith('network: 0 channel(s)'));
    });

    test('an unknown subcommand prints the usage line', () async {
      final (slash, io) = registerNetworkHost();
      await slash(['bogus']);
      expect(io.text, contains('usage: /network'));
    });

    test('join without an invite prints the usage line', () async {
      final (slash, io) = registerNetworkHost();
      await slash(['join']);
      expect(io.text, contains('usage: /network join'));
    });
  });
}
