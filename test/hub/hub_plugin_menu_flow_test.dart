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

import 'dart:convert';
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

/// A deterministic started hub for the `/dap start` pipeline tests: start
/// is a no-op (never touches the network), status is always connected,
/// and every `connectTo` is recorded. Lets the password/spawn/connect
/// steps run end-to-end without a real hub process.
final class _ScriptedHubPlugin extends hub.HubPlugin {
  _ScriptedHubPlugin({
    required Map<String, String> environment,
    required String home,
  }) : super(environment: environment, home: home);

  var startCalls = 0;
  final connectCalls = <String>[];

  @override
  Future<void> start({hub.HubIdentity? identity}) async {
    startCalls++;
  }

  @override
  Future<hub.HubStatus> status() async => const hub.HubStatus(
    connected: true,
    agentId: 'scripted-agent',
    name: 'scripted',
    url: 'ws://127.0.0.1:26499/ws',
    channels: [],
    welcomes: 0,
    hellos: 0,
  );

  @override
  Future<hub.DapConnection> connectTo(
    String host, {
    String? name,
    String? channel,
  }) async {
    connectCalls.add(host);
    return (
      ok: true,
      url: host,
      name: name,
      agentId: 'scripted-agent',
      channels: [?channel],
    );
  }
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

  /// Hermetic `/dap start` harness: probe/spawner/connect are all
  /// injected (no process spawn, no sockets). The probe answers [hubUp]
  /// until the (scripted) spawner runs, which flips it up — mirroring
  /// "spawn then poll". [spawnError] makes the spawner throw.
  (
    SlashCommand,
    _CapturingIo,
    Map<String, String>,
    _ScriptedHubPlugin,
    List<int>,
  )
  registerStartHost({
    Map<String, String>? environment,
    PluginAskLine? askLine,
    bool hubUp = false,
    Object? spawnError,
  }) {
    final env = environment ?? <String, String>{};
    final plugin = _ScriptedHubPlugin(environment: env, home: tempHome.path);
    var up = hubUp;
    final spawnPorts = <int>[];
    Future<bool> probe(int port) async => up;
    Future<void> spawner(int port) async {
      if (spawnError != null) throw spawnError;
      spawnPorts.add(port);
      up = true;
    }

    final host = HubPluginHost(
      plugin,
      environment: env,
      home: tempHome.path,
      localHubUrl: 'ws://127.0.0.1:26499/ws',
      hubHealthProbe: probe,
      hubSpawner: spawner,
    );
    final io = _CapturingIo();
    final context = PluginContext(
      env: MemoryExecutionEnv(cwd: '/work'),
      io: io,
      askLine: askLine,
    );
    host.register(context);
    return (context.slashCommands['/dap']!, io, env, plugin, spawnPorts);
  }

  File hubStateFile() => File('${tempHome.path}/.dap/hub.json');

  File dapConfigFile() => File('${tempHome.path}/.dap/config.json');

  group('/dap start pipeline (hermetic)', () {
    test('one step: generates the secret, prompts, persists the hub '
        'password, spawns, and connects', () async {
      final (slash, io, env, plugin, spawnPorts) = registerStartHost(
        askLine: (question, {secret = false}) async => 'hunter2',
      );
      await slash(['start']);

      expect(io.text, contains('master secret generated'));
      expect(io.text, contains('hub password saved to'));
      expect(io.text, contains('this session joined the protected hub'));
      expect(io.text, contains('DAP is up — ws://127.0.0.1:26499/ws'));
      // The client holds the HUB's password, not the generated session
      // secret (the prompt wins over the generated value).
      expect(env['DAP_MASTER_SECRET'], 'hunter2');
      expect(spawnPorts, [26499]);
      expect(plugin.connectCalls, ['ws://127.0.0.1:26499/ws']);
      // The boot dial + the slash-driven start share the serialized start.
      expect(plugin.startCalls, greaterThanOrEqualTo(1));

      // The hub state file: master secret + empty enrollments, 0600.
      final state = hubStateFile();
      expect(await state.exists(), isTrue);
      final decoded =
          jsonDecode(await state.readAsString()) as Map<String, dynamic>;
      expect(decoded['masterSecret'], 'hunter2');
      expect(decoded['clients'], <String, dynamic>{});
      expect(state.statSync().mode & 0x1FF, 0x180); // 0600

      // The dap config: pinned url + client secret for the next boot.
      final config =
          jsonDecode(await dapConfigFile().readAsString())
              as Map<String, dynamic>;
      expect(config['url'], 'ws://127.0.0.1:26499/ws');
      expect(config['clientSecret'], 'hunter2');
    });

    test('a saved hub password is reused without prompting and never '
        're-spawns a running hub', () async {
      final state = hubStateFile();
      await state.parent.create(recursive: true);
      await state.writeAsString(
        jsonEncode({
          'masterSecret': 'saved-pass',
          'clients': <String, String>{},
        }),
      );
      var prompted = false;
      final (slash, io, env, plugin, spawnPorts) = registerStartHost(
        environment: {'DAP_MASTER_SECRET': 'session-secret'},
        hubUp: true,
        askLine: (question, {secret = false}) async {
          prompted = true;
          return 'should-not-be-asked';
        },
      );
      await slash(['start']);

      expect(prompted, isFalse);
      expect(io.text, isNot(contains('master secret generated')));
      // The saved state password wins over the session env secret.
      expect(env['DAP_MASTER_SECRET'], 'saved-pass');
      final config =
          jsonDecode(await dapConfigFile().readAsString())
              as Map<String, dynamic>;
      expect(config['clientSecret'], 'saved-pass');
      expect(spawnPorts, isEmpty); // hub already up: no spawn
      expect(io.text, contains('DAP is up'));
      expect(plugin.connectCalls, hasLength(1));
    });

    test('a failed spawn reports the error and never connects', () async {
      final (slash, io, _, plugin, spawnPorts) = registerStartHost(
        spawnError: StateError('boom'),
      );
      await slash(['start']);

      expect(io.text, contains('could not start a local hub'));
      expect(io.text, contains('boom'));
      expect(io.text, isNot(contains('DAP is up')));
      expect(plugin.connectCalls, isEmpty);
      expect(spawnPorts, isEmpty);
    });

    test('a read-only environment refuses with the export hint and '
        'does nothing else', () async {
      final (slash, io, _, plugin, spawnPorts) = registerStartHost(
        environment: const {},
      );
      await slash(['start']);

      expect(io.text, contains('environment is read-only'));
      expect(io.text, contains('export DAP_MASTER_SECRET'));
      expect(io.text, isNot(contains('master secret generated')));
      expect(io.text, isNot(contains('DAP is up')));
      expect(spawnPorts, isEmpty);
      expect(plugin.connectCalls, isEmpty);
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

    test('the registry pins names, approval tiers, and required params', () {
      final (tools, _) = registerToolsHost();
      expect(
        [for (final tool in tools) tool.name],
        ['dap_status', 'dap_peers', 'dap_dm', 'dap_invite', 'dap_connect'],
      );
      // Read-only status/peers; anything that reaches the network stays
      // behind the exec approval gate.
      expect(
        [for (final tool in tools) tool.tier],
        [
          ApprovalTier.read,
          ApprovalTier.read,
          ApprovalTier.exec,
          ApprovalTier.exec,
          ApprovalTier.exec,
        ],
      );
      expect(tools[0].parameters['required'], isNull);
      expect(tools[1].parameters['required'], isNull);
      expect(tools[2].parameters['required'], ['to', 'text']);
      expect(tools[3].parameters['required'], ['nameOrId']);
      expect(tools[4].parameters['required'], ['host']);
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

  const leaveInvite =
      'wss://hub.fa1.dev/ws?channel=team'
      '#pub=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8'
      '&priv=AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA';

  /// Answers picks by exact menu title; an absent title takes the first
  /// option, an explicit null cancels the pick.
  PluginPickOption pickByTitle(Map<String, String?> answers) =>
      (title, options, {initialKey}) async =>
          answers.containsKey(title) ? answers[title] : options.first.$1;

  group('/network channels + leave (menu path)', () {
    (SlashCommand, _CapturingIo, List<Map<String, Object?>>)
    registerNetworkMenuHost({required PluginPickOption pick}) {
      final env = <String, String>{};
      final sessionRecords = <Map<String, Object?>>[];
      final plugin = hub.HubPlugin(environment: env, home: tempHome.path);
      final host = HubPluginHost(plugin, environment: env, home: tempHome.path);
      // Never dial a real hub from unit tests.
      host.scopedConnectOverride = (hubUrl) async {};
      final io = _CapturingIo();
      final context = PluginContext(
        env: MemoryExecutionEnv(cwd: tempHome.path),
        io: io,
        pickOption: pick,
        askLine: (question, {secret = false}) async => leaveInvite,
        appendSessionRecord: (type, data) async {
          sessionRecords.add(Map<String, Object?>.from(data));
        },
        readSessionRecords: (type) async => sessionRecords,
      );
      host.register(context);
      return (context.slashCommands['/network']!, io, sessionRecords);
    }

    test('a single-scope channel leaves directly and records the '
        'tombstone', () async {
      final (slash, io, records) = registerNetworkMenuHost(
        pick: pickByTitle({'Network': 'channels', '#team': 'leave'}),
      );
      await slash(['join', leaveInvite]);
      expect(records.single['channelId'], 'team');

      await slash([]);
      expect(io.text, contains('network: left #team [session]'));
      // The leave tombstone: the join record stays, the op is appended.
      expect(records.where((r) => r['op'] == 'leave'), hasLength(1));
    });

    test('a multi-scope leave asks which scope; cancelling keeps every '
        'scope', () async {
      final answers = <String, String?>{
        'Network': 'channels',
        '#team': 'leave',
        'Leave which scope?': null, // cancelled: nothing is left
      };
      final (slash, io, records) = registerNetworkMenuHost(
        pick: pickByTitle(answers),
      );
      // Session scope by args (scope pick falls through to the default),
      // then project scope via the wizard: #team is joined at two scopes.
      await slash(['join', leaveInvite]);
      expect(records.single['channelId'], 'team');

      answers['Network'] = 'join';
      answers['Scope — members can steer this agent'] = 'project';
      await slash([]);
      expect(io.text, contains('joined #team [project]'));
      expect(records, hasLength(1)); // session join only; project is a file

      answers['Network'] = 'channels';
      await slash([]); // channels → #team → leave → cancelled scope pick
      expect(io.text, isNot(contains('network: left')));
      expect(records, hasLength(1));
      final project =
          jsonDecode(
                await File('${tempHome.path}/.fah/dap.json').readAsString(),
              )
              as Map<String, dynamic>;
      expect((project['channels'] as List).single['channelId'], 'team');
    });
  });
}
