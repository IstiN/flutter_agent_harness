/// IT for the one-step local DAP hub (issue #304): `fa dap start/stop/
/// status` over the [DapHubController]. The hub itself is a real
/// [LocalHub] on an ephemeral loopback port (the `test/hub/fake_hub.dart`
/// pattern — real sockets on 127.0.0.1, never an external network); the
/// spawn/terminate/prompt seams are injected so no process is forked
/// here. The real-process E2E lives in
/// `test/integration/dap_cli_e2e_test.dart`.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart' as client;
import 'package:flutter_agent_harness/io.dart'
    show
        LocalHub,
        defaultHubStateFile,
        readHubState,
        writeHubState;
import 'package:test/test.dart';

import '../../bin/fah_dap_command.dart';
import '../../bin/hub_fabric_repository.dart' show hubFabricWired;

const timeout = Timeout(Duration(seconds: 20));

/// The hidden master-key prompt seam.
typedef SecretPrompt = Future<String?> Function(String question);

void main() {
  late Directory tempHome;

  setUp(() async {
    tempHome = await Directory.systemTemp.createTemp('fah-dap-cmd-');
  });

  tearDown(() async {
    if (await tempHome.exists()) {
      tempHome.deleteSync(recursive: true);
    }
  });

  /// A free loopback port (bind-close dance).
  Future<int> freePort() async {
    final probe = LocalHub(port: 0);
    await probe.start();
    final port = probe.url.port;
    await probe.stop();
    return port;
  }

  File stateFileFor() =>
      defaultHubStateFile(home: tempHome.path, environment: const {});

  String configPath() =>
      client.defaultDapConfigFile(tempHome.path, const {});

  /// File mode as octal (`600`), POSIX only; null elsewhere.
  Future<String?> modeOf(String path) async {
    if (!Platform.isLinux && !Platform.isMacOS) return null;
    final stat = Platform.isMacOS ? '-f' : '-c';
    final fmt = Platform.isMacOS ? '%Lp' : '%a';
    final result = await Process.run('stat', [stat, fmt, path]);
    if (result.exitCode != 0) return null;
    return (result.stdout as String).trim();
  }

  /// Builds a controller whose spawn seam brings up [hub] in-process
  /// (mirroring `fa hub serve`: the state file is wired so enrollments
  /// persist); probe/HTTP/WS paths are the REAL ones against loopback.
  /// [port] is the pre-agreed port ([hub] is constructed but not started
  /// before the spawn seam fires).
  DapHubController controllerFor(
    LocalHub hub,
    int port, {
    SecretPrompt? prompt,
    Future<bool> Function(int pid)? terminator,
  }) {
    return DapHubController(
      home: tempHome.path,
      environment: const {},
      url: 'ws://127.0.0.1:$port/ws',
      spawnHub: (url, masterSecret) async {
        await hub.start();
        return 1; // the in-process stand-in pid; the seam owns stopping
      },
      terminateHub: terminator ?? (_) async => true,
      secretPrompt: prompt,
    );
  }

  DapHubController attachUrl(
    String url, {
    SecretPrompt? prompt,
    Future<bool> Function(int pid)? terminator,
  }) {
    return DapHubController(
      home: tempHome.path,
      environment: const {},
      url: url,
      spawnHub: (url, secret) async => throw StateError('no spawn'),
      terminateHub: terminator ?? (_) async => true,
      secretPrompt: prompt,
    );
  }

  DapHubController attachController(
    LocalHub hub, {
    SecretPrompt? prompt,
    Future<bool> Function(int pid)? terminator,
  }) => attachUrl(
        hub.url.toString(),
        prompt: prompt,
        terminator: terminator,
      );

  /// Collects the controller's output lines for assertions.
  List<String> sinkOf(DapHubController controller) => controller.lines;

  group('fa dap start (AC1)', () {
    test(
      'clean machine, interactive: prompts the master key (hidden), '
      'starts a protected hub, enrolls, persists clientSecret — a second '
      'start attaches WITHOUT prompting',
      () async {
        final port = await freePort();
        final hub = LocalHub(port: port, stateFile: stateFileFor());
        addTearDown(() => hub.stop());
        final prompts = <String>[];
        final controller = controllerFor(
          hub,
          port,
          prompt: (question) {
            prompts.add(question);
            return Future.value('k1-master-key');
          },
        );

        final code = await controller.start();
        final lines = sinkOf(controller);
        expect(code, 0, reason: lines.join('\n'));
        expect(prompts, hasLength(1), reason: 'exactly one master-key prompt');
        final out = lines.join('\n');
        expect(out, contains('DAP hub on ws://127.0.0.1:$port'));
        expect(out, contains('enrolled'));
        expect(out, contains('fabric enabled'));

        // The hub is protected with the entered master key and persisted
        // its enrollment (the `fa hub serve` state contract).
        final hubState = readHubState(stateFileFor());
        expect(hubState.masterSecret, 'k1-master-key');
        expect(hubState.clients, isNotEmpty,
            reason: 'the hub persisted the issued client secret');

        // The CLI persisted the hub-issued clientSecret — never the
        // master key (AC6).
        final config = client.readDapConfig(configPath());
        expect(config['clientSecret'], isA<String>());
        expect(config['clientSecret'], isNot('k1-master-key'));

        // The pid/state file exists so a second instance attaches (E4).
        final state = parseDapLocalHubState(
          File(dapHubPidFileFor(tempHome.path)).readAsStringSync(),
        );
        expect(state, isNotNull);
        expect(state!.port, port);

        // SECOND START: attach — no spawn, no prompt.
        final controller2 = attachController(
          hub,
          prompt: (q) {
            prompts.add(q);
            return Future.value('k1-master-key');
          },
        );
        final code2 = await controller2.start();
        final out2 = sinkOf(controller2).join('\n');
        expect(code2, 0, reason: out2);
        expect(out2, contains('already running'));
        expect(prompts, hasLength(1),
            reason: 'the second start attaches without prompting');
      },
      timeout: timeout,
    );

    test(
      'clean machine, non-interactive: open hub, zero prompts (AC5)',
      () async {
        final port = await freePort();
        final hub = LocalHub(port: port, stateFile: stateFileFor());
        addTearDown(() => hub.stop());
        final controller = controllerFor(hub, port);
        final code = await controller.start();
        final out = sinkOf(controller).join('\n');
        expect(code, 0, reason: out);
        expect(out, contains('DAP hub on ws://127.0.0.1:$port'));
        // No master key was set: the hub stays open (the zero-config
        // extension default), nothing prompted.
        expect(readHubState(stateFileFor()).masterSecret, isNull);
      },
      timeout: timeout,
    );

    test(
      'master key already in ~/.dap/hub.json: restart enrolls without a '
      'prompt (hub crash recovery, E2/E4)',
      () async {
        final port = await freePort();
        final hub = LocalHub(port: port, stateFile: stateFileFor());
        addTearDown(() => hub.stop());
        await writeHubState(
          stateFileFor(),
          masterSecret: 'stored-master',
          clients: const {},
        );
        final controller = controllerFor(
          hub,
          port,
          prompt: (q) async {
            fail('no prompt expected: $q');
          },
        );
        final code = await controller.start();
        final out = sinkOf(controller).join('\n');
        expect(code, 0, reason: out);
        expect(out, contains('enrolled'));
        expect(
          client.readDapConfig(configPath())['clientSecret'],
          isNot('stored-master'),
        );
      },
      timeout: timeout,
    );

    test('secrets hygiene (AC6): modes and byte-scan', () async {
      final port = await freePort();
      final hub = LocalHub(port: port, stateFile: stateFileFor());
      addTearDown(() => hub.stop());
      final controller = controllerFor(
        hub,
        port,
        prompt: (q) => Future.value('hygiene-master-key'),
      );
      await controller.start();
      final out = sinkOf(controller).join('\n');

      // 0600 on the secret-bearing files (POSIX only).
      expect(await modeOf(configPath()), anyOf('600', '0600'));
      expect(await modeOf(stateFileFor().path), anyOf('600', '0600'));

      // The identity key exists 0600 under ~/.dap/keys/fah/ (first start).
      final keys = Directory('${tempHome.path}/.dap/keys/fah');
      expect(await keys.exists(), isTrue);
      final keyFile = keys.listSync().single;
      expect(await modeOf(keyFile.path), anyOf('600', '0600'));

      // Byte-scan: the master key never appears in the output lines or
      // the client config (only the hub's own state file may hold it —
      // it is the hub-side password store, 0600).
      expect(out, isNot(contains('hygiene-master-key')));
      expect(
        await File(configPath()).readAsString(),
        isNot(contains('hygiene-master-key')),
      );
    }, timeout: timeout);
  });

  group('E1: foreign server on the port', () {
    test('start detects a non-DAP /healthz answer and refuses to enroll',
        () async {
      final port = await freePort();
      final server = await HttpServer.bind('127.0.0.1', port);
      addTearDown(() => server.close(force: true));
      unawaited(
        server.listen((request) {
          request.response
            ..statusCode = 200
            ..write('{"service": "not-a-dap-hub"}')
            ..close();
        }).asFuture<void>(),
      );

      final controller = DapHubController(
        home: tempHome.path,
        environment: const {},
        url: 'ws://127.0.0.1:$port/ws',
        spawnHub: (url, secret) async =>
            throw StateError('E1 must not spawn over a foreign server'),
        terminateHub: (_) async => true,
        secretPrompt: (q) async {
          fail('E1 must not prompt: $q');
        },
      );
      final code = await controller.start();
      expect(code, 1);
      final out = controller.lines.join('\n');
      expect(out, contains('not a DAP hub'));
      expect(out, contains('$port'), reason: 'the error names the port');
      // No enrollment happened: no client credential was persisted.
      expect(client.readDapConfig(configPath()), isEmpty);
    }, timeout: timeout);
  });

  group('E3: wrong master key', () {
    test(
      're-prompts up to 3x, then exits with the manual hint; the '
      'rejected secrets are never persisted',
      () async {
        final hub = LocalHub(masterSecret: 'right-key');
        await hub.start();
        addTearDown(() => hub.stop());
        final attempts = <String>[];
        final controller = attachController(
          hub,
          prompt: (q) {
            attempts.add(q);
            return Future.value('wrong-${attempts.length}');
          },
        );
        final code = await controller.start();
        expect(code, 1);
        expect(attempts, hasLength(3), reason: 'exactly three prompts');
        final out = controller.lines.join('\n');
        expect(out, contains('manual'),
            reason: 'the final failure carries the manual hint');
        // None of the wrong keys leaked into output or config.
        for (var i = 1; i <= 3; i++) {
          expect(out, isNot(contains('wrong-$i')));
        }
        expect(client.readDapConfig(configPath())['clientSecret'], isNull);
        // The hub never enrolled a stranger.
        expect(hub.agentIds, isEmpty);
      },
      timeout: timeout,
    );
  });

  group('fa dap stop (AC2, E4)', () {
    test(
      'stop names connected peers, stops the hub, clears the state file; '
      'a second stop is a calm no-op',
      () async {
        final port = await freePort();
        final hub = LocalHub(port: port, stateFile: stateFileFor());
        final starter = controllerFor(hub, port);
        expect(await starter.start(), 0,
            reason: sinkOf(starter).join('\n'));

        // A second client playing the browser extension.
        final browser = client.HubClient(
          config: client.HubConfig(url: hub.url.toString(), name: 'Browser'),
          identity: await client.HubIdentity.generate(),
        );
        await browser.connect();
        addTearDown(() => browser.disconnect());

        final stopper = attachController(
          hub,
          terminator: (_) async {
            await hub.stop();
            return true;
          },
        );
        final code = await stopper.stop();
        final out = sinkOf(stopper).join('\n');
        expect(code, 0, reason: out);
        expect(out, contains('Browser'),
            reason: 'the stop warning names the connected peer');
        expect(out, contains('DAP hub stopped'));
        // The hub is down and the pid state is gone (no zombie, E4).
        expect(await healthzDown(port), isTrue);
        expect(
          await File(dapHubPidFileFor(tempHome.path)).exists(),
          isFalse,
        );

        // Second stop: calm no-op (the hub object is dead — address by
        // the known url).
        final stopper2 = attachUrl('ws://127.0.0.1:$port/ws');
        expect(await stopper2.stop(), 0);
        expect(sinkOf(stopper2).join('\n'), contains('not running'));
      },
      timeout: timeout,
    );
  });

  group('fa dap status', () {
    test('running: url + peers; stopped after termination', () async {
      final port = await freePort();
      final hub = LocalHub(port: port, stateFile: stateFileFor());
      final starter = controllerFor(hub, port);
      await starter.start();

      final status = attachController(hub);
      await status.status();
      var out = sinkOf(status).join('\n');
      expect(out, contains('running'));
      expect(out, contains('ws://127.0.0.1:$port/ws'));

      final url = 'ws://127.0.0.1:$port/ws';
      await hub.stop();
      final deadStatus = attachUrl(url);
      await deadStatus.status();
      out = sinkOf(deadStatus).join('\n');
      expect(out, contains('not running'));
    }, timeout: timeout);
  });

  group('E6: the fabric.hub kill-switch gate', () {
    test('hubFabricWired mirrors the images.registry pattern', () {
      // All three on: the composite fabric is wired.
      expect(
        hubFabricWired(
          hubPluginEnabled: true,
          dapUnlocked: true,
          fabricHubAllowed: true,
        ),
        isTrue,
      );
      // fabric.hub: false — byte-identical legacy behavior.
      expect(
        hubFabricWired(
          hubPluginEnabled: true,
          dapUnlocked: true,
          fabricHubAllowed: false,
        ),
        isFalse,
      );
      // No DAP_MASTER_SECRET (never started): legacy too.
      expect(
        hubFabricWired(
          hubPluginEnabled: true,
          dapUnlocked: false,
          fabricHubAllowed: true,
        ),
        isFalse,
      );
      // Plugin not enabled: no hub layer at all.
      expect(
        hubFabricWired(
          hubPluginEnabled: false,
          dapUnlocked: true,
          fabricHubAllowed: true,
        ),
        isFalse,
      );
    });
  });

  group('stop on hosts without a pid probe (the Windows fix)', () {
    // dart:io cannot probe pid liveness on Windows (`kill -0` does not
    // exist), so the default terminate used to report "alive" forever:
    // `fa dap stop` false-failed with exit 1 and left a stale pid file
    // while the hub was already dead. The promised fallback: the hub
    // PORT draining is the liveness signal. `pidProbePosix: false`
    // pins the Windows path on any OS; the kill seam records signals
    // so no real process is touched.
    test('dapPortAnswers: a live listener answers, a drained one does not',
        () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(() => server.close());
      final url = Uri.parse('ws://127.0.0.1:${server.port}/ws');
      expect(await dapPortAnswers(url), isTrue);
      await server.close();
      expect(await dapPortAnswers(url), isFalse);
    });

    test(
      'no pid probe: the port draining (not the pid) decides, no escalation',
      () async {
        final server = await ServerSocket.bind('127.0.0.1', 0);
        final url = 'ws://127.0.0.1:${server.port}/ws';
        // The "hub" dies mid-grace — the port check must see it drain
        // and report stopped even though the pid can never be probed.
        final timer = Timer(
          const Duration(milliseconds: 300),
          () => unawaited(server.close()),
        );
        addTearDown(timer.cancel);
        final signals = <ProcessSignal>[];
        final stopped = await defaultDapTerminate(
          4190203, // never signaled: the kill seam records only
          url,
          pidProbePosix: false,
          kill: (pid, signal) => signals.add(signal),
          grace: const Duration(seconds: 2),
          force: const Duration(seconds: 1),
        );
        expect(stopped, isTrue, reason: 'the port drained → hub gone');
        expect(
          signals,
          [ProcessSignal.sigterm],
          reason: 'no SIGKILL escalation once the port drains',
        );
      },
      timeout: timeout,
    );

    test(
      'port never drains: SIGTERM → SIGKILL escalation, then honest false '
      '(no false success, no stale "stopped" claim)',
      () async {
        final server = await ServerSocket.bind('127.0.0.1', 0);
        addTearDown(() => server.close());
        final signals = <ProcessSignal>[];
        final stopped = await defaultDapTerminate(
          4190203,
          'ws://127.0.0.1:${server.port}/ws',
          pidProbePosix: false,
          kill: (pid, signal) => signals.add(signal),
          grace: const Duration(milliseconds: 400),
          force: const Duration(milliseconds: 300),
        );
        expect(stopped, isFalse);
        expect(signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
      },
      timeout: timeout,
    );

    test('POSIX path still probes the pid (platform-guarded)', () async {
      // kill -0 is a POSIX shell dance — Windows hosts skip this test.
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final signals = <ProcessSignal>[];
      final stopped = await defaultDapTerminate(
        4190203, // certainly dead: the first poll sees it gone
        'ws://127.0.0.1:1/ws',
        pidProbePosix: true,
        kill: (pid, signal) => signals.add(signal),
      );
      expect(stopped, isTrue);
      expect(signals, [ProcessSignal.sigterm]);
    }, timeout: timeout);
  });

  group('presence probe matches the ANSWER by replyTo', () {
    // A DAP-shaped endpoint that PUSHES an unsolicited partial presence
    // frame on connect (a broadcast racing the query answer) before
    // answering the actual presence_query with the full roster. The
    // probe must take the replyTo-matched ANSWER, not the racing push —
    // otherwise stop/status can report a partial roster.
    test('a racing presence push (no replyTo) never completes the probe',
        () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      unawaited(
        server.listen((request) async {
          if (request.uri.path == '/healthz') {
            request.response.statusCode = 200;
            await request.response.close();
            return;
          }
          if (request.uri.path != '/ws') {
            request.response.statusCode = 404;
            await request.response.close();
            return;
          }
          final ws = await WebSocketTransformer.upgrade(request);
          // The racing broadcast: presence with NO replyTo and a
          // partial (online-only) roster.
          ws.add(jsonEncode({
            'op': 'presence',
            'agents': [
              {'name': 'Browser', 'online': true},
            ],
          }));
          ws.listen((dynamic data) {
            final frame = jsonDecode(data as String);
            if (frame is Map && frame['op'] == 'presence_query') {
              ws.add(jsonEncode({
                'op': 'presence',
                'replyTo': frame['id'],
                'agents': [
                  {'name': 'Browser', 'online': true},
                  {'name': 'Editor', 'online': true},
                  {'name': 'Ghost', 'online': false},
                ],
              }));
            }
          });
        }).asFuture<void>(),
      );

      final controller = attachUrl('ws://127.0.0.1:${server.port}/ws');
      final probe = await controller.probeHub();
      expect(probe.kind, DapHubProbeKind.running);
      expect(
        probe.peers,
        ['Browser', 'Editor'],
        reason: 'the ANSWER roster (replyTo-matched, online-only), not '
            'the racing partial push',
      );
    }, timeout: timeout);

    test(
      'a hub that never echoes replyTo degrades to "roster unknown", '
      'not a partial guess',
      () async {
        final server = await HttpServer.bind('127.0.0.1', 0);
        addTearDown(() => server.close(force: true));
        unawaited(
          server.listen((request) async {
            if (request.uri.path == '/healthz') {
              request.response.statusCode = 200;
              await request.response.close();
              return;
            }
            if (request.uri.path != '/ws') {
              request.response.statusCode = 404;
              await request.response.close();
              return;
            }
            final ws = await WebSocketTransformer.upgrade(request);
            ws.add(jsonEncode({
              'op': 'presence', // legacy shape: no replyTo echo
              'agents': [
                {'name': 'Browser', 'online': true},
              ],
            }));
          }).asFuture<void>(),
        );

        final controller = attachUrl('ws://127.0.0.1:${server.port}/ws');
        final probe = await controller.probeHub();
        expect(probe.kind, DapHubProbeKind.running);
        expect(probe.peers, isEmpty,
            reason: 'no replyTo-matched answer → running, roster unknown');
      },
      timeout: timeout,
    );
  });
}

Future<bool> healthzDown(int port) async {
  try {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    final response = await (await http.get(
      '127.0.0.1',
      port,
      '/healthz',
    )).close();
    await response.drain<void>();
    http.close();
    return response.statusCode != 200;
  } on Object {
    return true;
  }
}
