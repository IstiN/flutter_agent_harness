/// UT for the `fa hub serve` CLI dispatch (issue #304): flag parsing,
/// secret resolution, the idempotent/bind/success serve paths, and the
/// graceful-exit seam — the CRAP-ratchet coverage for the split
/// `runHubCommand` dispatcher. The SIGINT/SIGTERM wiring stays covered
/// by `test/hub/fah_hub_serve_test.dart`.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_harness/io.dart'
    show LocalHub, defaultHubStateFile, readHubState;
import 'package:flutter_agent_harness/src/hub/dap_local_hub_state.dart'
    show parseDapLocalHubState;
import 'package:test/test.dart';

import '../../bin/fah_dap_command.dart' show envHubPidFile;
import '../../bin/fah_hub_serve.dart';

const timeout = Timeout(Duration(seconds: 20));

void main() {
  late Directory tempHome;

  setUp(() async {
    tempHome = await Directory.systemTemp.createTemp('fah-hub-cli-');
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

  group('parseFlagValues / parseHubServeSpec', () {
    test('collapses --flag value pairs; later duplicates win', () {
      expect(parseFlagValues(const ['--port', '9000', '--secret', 's']), {
        '--port': '9000',
        '--secret': 's',
      });
      expect(parseFlagValues(const ['--port', '1', '--port', '2']), {
        '--port': '2',
      });
    });

    test('positional noise and valueless trailing flags are ignored', () {
      expect(parseFlagValues(const ['x', '--port']), isEmpty);
    });

    test('port: a bad value keeps the default; secret passes through', () {
      expect(parseHubServeSpec(const []), (
        port: defaultHubServePort,
        flagSecret: null,
      ));
      expect(parseHubServeSpec(const ['--port', 'x']), (
        port: defaultHubServePort,
        flagSecret: null,
      ));
      expect(parseHubServeSpec(const ['--port', '9100', '--secret', 'k']), (
        port: 9100,
        flagSecret: 'k',
      ));
    });
  });

  group('hubPidFileFor', () {
    test('DAP_HUB_PID_FILE wins, then home, then HOME/USERPROFILE', () {
      expect(
        hubPidFileFor(environment: {envHubPidFile: '/tmp/p'}).path,
        '/tmp/p',
      );
      expect(
        hubPidFileFor(environment: const {'HOME': '/h'}, home: '/w').path,
        contains('/w'),
      );
      expect(
        hubPidFileFor(environment: const {'HOME': '/h'}).path,
        contains('/h'),
      );
      expect(
        hubPidFileFor(environment: const {'USERPROFILE': '/u'}).path,
        contains('/u'),
      );
    });
  });

  group('resolveHubServeSecret', () {
    test('--secret beats DAP_HUB_SECRET beats the persisted state', () async {
      final stateFile = stateFileFor();
      await stateFile.parent.create(recursive: true);
      stateFile.writeAsStringSync('{"masterSecret":"stored","clients":{}}');
      expect(
        await resolveHubServeSecret(
          stateFile,
          flagSecret: 'flag',
          environment: const {},
        ),
        'flag',
      );
      expect(
        await resolveHubServeSecret(
          stateFile,
          environment: {'DAP_HUB_SECRET': 'env'},
        ),
        'env',
      );
      expect(
        await resolveHubServeSecret(stateFile, environment: const {}),
        'stored',
      );
    });

    test(
      'nothing stored and no interactive terminal: null, no prompt',
      () async {
        var prompted = 0;
        final secret = await resolveHubServeSecret(
          File('${tempHome.path}/no-hub.json'),
          environment: const {},
          prompt: (_) async {
            prompted++;
            return 'p';
          },
        );
        expect(secret, isNull);
        expect(prompted, 0, reason: 'dart test has no terminal');
      },
    );
  });

  group('persistHubSecretChoice', () {
    test('a chosen password is stored', () async {
      final stateFile = File('${tempHome.path}/nested/hub.json');
      await persistHubSecretChoice(stateFile, 'pw');
      expect(readHubState(stateFile).masterSecret, 'pw');
    });

    test('an explicit empty choice is remembered as open', () async {
      final stateFile = stateFileFor();
      await stateFile.parent.create(recursive: true);
      await persistHubSecretChoice(stateFile, '');
      expect(readHubState(stateFile).masterSecret, isNull);
      expect(stateFile.existsSync(), isTrue);
    });

    test('persistence failure never throws (best-effort)', () async {
      // A file where the state dir should be: createSync must fail.
      final blocker = File('${tempHome.path}/blocker')..writeAsStringSync('x');
      await persistHubSecretChoice(File('${blocker.path}/hub.json'), 'pw');
    });
  });

  group('runHubCommand dispatch', () {
    test('no verb / unknown verb: usage, exit 1', () async {
      expect(await runHubCommand(const []), 1);
      expect(await runHubCommand(const ['explode']), 1);
    });

    test(
      'serve against a live hub: idempotent no-op, exit 0, no pid file',
      () async {
        final port = await freePort();
        final hub = LocalHub(port: port, stateFile: stateFileFor());
        await hub.start();
        addTearDown(() => hub.stop());
        final pidFile = File('${tempHome.path}/hub.pid');
        var loopRan = 0;
        final code = await runHubCommand(
          ['serve', '--port', '$port'],
          home: tempHome.path,
          environment: {envHubPidFile: pidFile.path},
          serveLoop: (_, _) async => loopRan++,
        );
        expect(code, 0);
        expect(loopRan, 0, reason: 'the already-running path never serves');
        expect(pidFile.existsSync(), isFalse);
      },
      timeout: timeout,
    );

    test('serve onto a taken port: bind failure, exit 1', () async {
      final port = await freePort();
      final blocker = await ServerSocket.bind('127.0.0.1', port);
      // A non-HTTP listener: connections die instantly, so the
      // healthz probe reports down and the bind is what fails.
      final sub = blocker.listen((socket) => socket.destroy());
      addTearDown(() async {
        await sub.cancel();
        await blocker.close();
      });
      final code = await runHubCommand(
        ['serve', '--port', '$port'],
        home: tempHome.path,
        environment: {envHubPidFile: '${tempHome.path}/hub.pid'},
      );
      expect(code, 1);
    }, timeout: timeout);

    test(
      'serve happy path: hub up + protected, pid state written, exit 0',
      () async {
        final port = await freePort();
        final pidFile = File('${tempHome.path}/hub.pid');
        LocalHub? served;
        final code = await runHubCommand(
          ['serve', '--port', '$port', '--secret', 's3cret'],
          home: tempHome.path,
          environment: {envHubPidFile: pidFile.path},
          serveLoop: (hub, _) async {
            served = hub;
            expect(
              await hubHealthz(port),
              isTrue,
              reason: 'the new hub answers /healthz',
            );
          },
        );
        expect(code, 0);
        expect(served, isNotNull);
        expect(served!.isProtected, isTrue);
        final state = parseDapLocalHubState(pidFile.readAsStringSync());
        expect(state, isNotNull);
        expect(state!.port, port);
        expect(state.pid, pid); // served in-process: the test pid
        await served!.stop();
      },
      timeout: timeout,
    );

    test('serve onto a taken port with NO injected environment (the '
        'production wiring): bind failure, exit 1', () async {
      final port = await freePort();
      final blocker = await ServerSocket.bind('127.0.0.1', port);
      final sub = blocker.listen((socket) => socket.destroy());
      addTearDown(() async {
        await sub.cancel();
        await blocker.close();
      });
      // No environment/home overrides: the state and pid paths must
      // still resolve under the injected home (tempHome), never the
      // real ~/.dap.
      final code = await runHubCommand([
        'serve',
        '--port',
        '$port',
      ], home: tempHome.path);
      expect(code, 1);
    }, timeout: timeout);

    test(
      'serve with an unwritable pid path: best-effort pid state, still 0',
      () async {
        final port = await freePort();
        final blocker = File('${tempHome.path}/blocker')
          ..writeAsStringSync('x');
        LocalHub? served;
        final code = await runHubCommand(
          ['serve', '--port', '$port'],
          home: tempHome.path,
          environment: {
            // A file where the pid directory should be: the pid-state
            // write fails and must never take the hub down with it.
            envHubPidFile: '${blocker.path}/hub.pid',
          },
          serveLoop: (hub, _) async {
            served = hub;
          },
        );
        expect(code, 0);
        await served?.stop();
      },
      timeout: timeout,
    );
  });

  group('hubGracefulExit (the seam)', () {
    test('stops the hub, clears the pid state, exits 0', () async {
      final port = await freePort();
      final hub = LocalHub(port: port, stateFile: stateFileFor());
      await hub.start();
      final pidFile = File('${tempHome.path}/gone.pid')
        ..writeAsStringSync('{"pid":1,"port":1,"startedAt":"x"}');
      final exits = <int>[];
      await hubGracefulExit(
        hub,
        pidFile,
        // Real subscriptions: the cancel loop must run, not be skipped.
        watchHubTerminateSignals(() {}),
        exitProcess: exits.add,
      );
      expect(exits, [0]);
      expect(pidFile.existsSync(), isFalse);
      expect(await hubHealthz(port), isFalse, reason: 'the hub stopped');
    }, timeout: timeout);

    test('a stuck pid file never blocks shutdown', () async {
      final port = await freePort();
      final hub = LocalHub(port: port, stateFile: stateFileFor());
      await hub.start();
      // A directory where the pid file should be: deleteSync throws.
      final stuck = Directory('${tempHome.path}/stuck.pid')
        ..createSync(recursive: true);
      final exits = <int>[];
      await hubGracefulExit(
        hub,
        File(stuck.path),
        const [],
        exitProcess: exits.add,
      );
      expect(exits, [0]);
      await hub.stop();
    }, timeout: timeout);
  });

  test(
    'wireHubTerminate: wired but not fired — the hub keeps serving',
    () async {
      final port = await freePort();
      final hub = LocalHub(port: port, stateFile: stateFileFor());
      await hub.start();
      final exits = <int>[];
      final subs = wireHubTerminate(
        hub,
        stateFileFor(),
        exitProcess: exits.add,
      );
      // Nothing terminated the hub: still up, no exit.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await hubHealthz(port), isTrue);
      expect(exits, isEmpty);
      for (final sub in subs) {
        await sub.cancel();
      }
      await hub.stop();
    },
    timeout: timeout,
  );

  test('hubTerminateHandler: firing it runs the graceful exit', () async {
    final port = await freePort();
    final hub = LocalHub(port: port, stateFile: stateFileFor());
    await hub.start();
    final pidFile = File('${tempHome.path}/fired.pid')
      ..writeAsStringSync('{"pid":1,"port":1,"startedAt":"x"}');
    final exits = <int>[];
    final fire = hubTerminateHandler(
      hub,
      pidFile,
      watchHubTerminateSignals(() {}),
      exitProcess: exits.add,
    );
    fire();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(exits, [0]);
    expect(pidFile.existsSync(), isFalse);
    expect(await hubHealthz(port), isFalse);
  }, timeout: timeout);
}
