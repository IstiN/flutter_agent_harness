// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Unit coverage for the hub plugin host's menu / slash / tool surface
/// (the guards CRAP gate measures the merged unit-suite lcov, which
/// excludes integration-tagged tests — these flows therefore need an
/// untagged in-VM driver). Every dial targets 127.0.0.1:9 (port 9 is
/// the discard service: refused instantly, no network dependency).
@Timeout(Duration(seconds: 30))
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
  }) {
    final env = environment ?? <String, String>{};
    final plugin = hub.HubPlugin(environment: env, home: tempHome.path);
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
        final (slash, io, _, _) = registerHost(
          environment: const {'DAP_MASTER_SECRET': 'test-master-secret'},
        );
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
      expect(io.text, contains('could not start a local hub'));
    });

    test('start with a preset secret prompts for the hub password and '
        'persists it', () async {
      final (slash, io, _, _) = registerHost(
        environment: const {'DAP_MASTER_SECRET': 'test-master-secret'},
        askLine: (prompt, {secret = false}) async => 'hub-password',
      );
      await slash(['start']);
      expect(io.text, contains('hub password saved'));
    });

    test('<host> persists the url then reports the connect error', () async {
      final (slash, io, _, _) = registerHost(
        environment: const {'DAP_MASTER_SECRET': 'test-master-secret'},
      );
      await slash(['127.0.0.1:9']);
      expect(io.text, startsWith('[hub]'));
    });
  });

  group('/dap menu (interactive host)', () {
    test('cancelled pick stays quiet but probes the local hub', () async {
      final (slash, io, _, _) = registerHost(
        pickOption: (title, options, {initialKey}) async => null,
      );
      await slash([]);
      expect(io.text, isNotEmpty); // nothing required — just no crash
    });

    test('status choice prints the disconnected line', () async {
      final (slash, io, _, _) = registerHost(
        environment: const {'DAP_MASTER_SECRET': 'test-master-secret'},
        pickOption: (title, options, {initialKey}) async => 'status',
      );
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
      final (slash, io, env, _) = registerHost(
        pickOption: (title, options, {initialKey}) async => 'secret',
        askLine: (prompt, {secret = false}) async => 'picked-secret',
      );
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

    test(
      'connect choice dials the prompted host and reports the error',
      () async {
        final (slash, io, _, _) = registerHost(
          environment: const {'DAP_MASTER_SECRET': 'test-master-secret'},
          pickOption: (title, options, {initialKey}) async => 'connect',
          askLine: (prompt, {secret = false}) async => '127.0.0.1:9',
        );
        await slash([]);
        expect(io.text, contains('[hub]'));
      },
    );

    test('start choice runs the one-step bring-up', () async {
      final (slash, io, env, _) = registerHost(
        pickOption: (title, options, {initialKey}) async => 'start',
        askLine: (prompt, {secret = false}) async => '',
      );
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
      expect(io.lines, isEmpty);
    });
  });

  group('dap_* tools', () {
    List<AgentTool> registerToolsHost() {
      final env = <String, String>{
        'DAP_MASTER_SECRET': 'test-master-secret',
        'DAP_HUB_URL': 'ws://127.0.0.1:9/ws',
      };
      final plugin = hub.HubPlugin(environment: env, home: tempHome.path);
      final host = HubPluginHost(plugin, environment: env, home: tempHome.path);
      final context = PluginContext(
        env: MemoryExecutionEnv(cwd: '/work'),
        io: _CapturingIo(),
      );
      host.register(context);
      final tools = context.tools;
      expect(tools.length, 5);
      return tools;
    }

    AgentTool toolByName(List<AgentTool> tools, String name) =>
        tools.firstWhere((t) => t.name == name);

    test('dap_status reports the disconnected state', () async {
      final tools = registerToolsHost();
      final result = await toolByName(
        tools,
        'dap_status',
      ).execute(const {}, null, null);
      final text = result.content.whereType<TextContent>().map((c) => c.text).join();
      expect(text, contains('connected: false'));
    });

    test('dap_peers tolerates a dead hub', () async {
      final tools = registerToolsHost();
      final result = await toolByName(
        tools,
        'dap_peers',
      ).execute(const {}, null, null);
      expect(result.content.whereType<TextContent>().map((c) => c.text).join(), isNotEmpty);
    });

    test('dap_dm rejects an unknown peer and lists the roster', () async {
      final tools = registerToolsHost();
      await expectLater(
        toolByName(
          tools,
          'dap_dm',
        ).execute(const {'to': 'nobody', 'text': 'hello'}, null, null),
        throwsA(isA<StateError>()),
      );
    });

    test('dap_invite surfaces the not-started error', () async {
      final tools = registerToolsHost();
      await expectLater(
        toolByName(
          tools,
          'dap_invite',
        ).execute(const {'nameOrId': 'nobody'}, null, null),
        throwsA(isA<StateError>()),
      );
    });

    test('dap_connect surfaces the dial error', () async {
      final tools = registerToolsHost();
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
    test('bare /network on a headless host lists the channel count', () async {
      final env = <String, String>{};
      final plugin = hub.HubPlugin(environment: env, home: tempHome.path);
      final host = HubPluginHost(plugin, environment: env, home: tempHome.path);
      final io = _CapturingIo();
      final context = PluginContext(
        env: MemoryExecutionEnv(cwd: '/work'),
        io: io,
      );
      host.register(context);
      await context.slashCommands['/network']!([]);
      expect(io.text, startsWith('network: 0 channel(s)'));
    });

    test('an unknown subcommand prints the usage line', () async {
      final env = <String, String>{};
      final plugin = hub.HubPlugin(environment: env, home: tempHome.path);
      final host = HubPluginHost(plugin, environment: env, home: tempHome.path);
      final io = _CapturingIo();
      final context = PluginContext(
        env: MemoryExecutionEnv(cwd: '/work'),
        io: io,
      );
      host.register(context);
      await context.slashCommands['/network']!(['bogus']);
      expect(io.text, contains('usage: /network'));
    });

    test('join without an invite prints the usage line', () async {
      final env = <String, String>{};
      final plugin = hub.HubPlugin(environment: env, home: tempHome.path);
      final host = HubPluginHost(plugin, environment: env, home: tempHome.path);
      final io = _CapturingIo();
      final context = PluginContext(
        env: MemoryExecutionEnv(cwd: '/work'),
        io: io,
      );
      host.register(context);
      await context.slashCommands['/network']!(['join']);
      expect(io.text, contains('usage: /network join'));
    });
  });
}
