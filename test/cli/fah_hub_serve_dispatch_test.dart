/// UT for the `fa hub serve` CLI dispatch (issue #304): flag parsing,
/// secret resolution, the usage-exit dispatch path, and the
/// graceful-exit seam — the CRAP-ratchet coverage for the split
/// `runHubCommand` dispatcher. The SIGINT/SIGTERM wiring stays covered
/// by `test/hub/fah_hub_serve_test.dart`.
///
/// The port-binding serve paths (taken-port binds, the live-hub
/// idempotent no-op, the happy path, the unwritable-pid path) live in
/// `fah_hub_serve_ports_test.dart` — they bind real loopback ports and
/// flake under the gate's parallel run on macOS (gh-740 M2), so they
/// carry `@Tags(['io', 'integration'])` and stay OUT of this
/// gate-included file. This file must keep covering
/// `bin/fah_hub_serve.dart`: the CRAP ratchet (crap4dart.yaml) measures
/// coverage from exactly the gate selector
/// (`dart test --coverage --exclude-tags integration`).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_harness/io.dart'
    show LocalHub, defaultHubStateFile, readHubState;
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
        flagBind: null,
      ));
      expect(parseHubServeSpec(const ['--port', 'x']), (
        port: defaultHubServePort,
        flagSecret: null,
        flagBind: null,
      ));
      expect(parseHubServeSpec(const ['--port', '9100', '--secret', 'k']), (
        port: 9100,
        flagSecret: 'k',
        flagBind: null,
      ));
      expect(parseHubServeSpec(const ['--bind', 'lan']), (
        port: defaultHubServePort,
        flagSecret: null,
        flagBind: 'lan',
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

  /// A free loopback port (bind-close dance). The port-binding SERVE
  /// paths live in fah_hub_serve_ports_test.dart; the graceful-exit seam
  /// above needs short-lived hubs on free ports and is gate-safe.
  Future<int> freePort() async {
    final probe = LocalHub(port: 0);
    await probe.start();
    final port = probe.url.port;
    await probe.stop();
    return port;
  }
}
