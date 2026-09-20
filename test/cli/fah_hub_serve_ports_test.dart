/// Port-binding UT for the `fa hub serve` CLI dispatch (issue #304;
/// gh-740 M2): the serve paths that bind real loopback ports — the
/// taken-port bind failures, the live-hub idempotent no-op, the happy
/// path, and the unwritable-pid best-effort path.
///
/// Quarantined from the pre-commit gate / CI: these tests bind real
/// loopback ports and flake under the gate's parallel run on macOS
/// ("shared flag to bind() needs to be true if binding multiple times").
/// `integration` is stacked on `io` — the gate and CI exclude only
/// `integration` (ci_fast_gate.sh, ci.yml), so `io` alone would stay in.
/// The socket-free groups (flag parsing, pid-path resolution, secret
/// resolution/persistence, usage-exit dispatch, the graceful-exit seam)
/// stay gate-included in fah_hub_serve_dispatch_test.dart — they carry
/// the CRAP-ratchet coverage for `bin/fah_hub_serve.dart`.
@TestOn('vm')
@Tags(['io', 'integration'])
library;

import 'dart:io';

import 'package:flutter_agent_harness/io.dart'
    show LocalHub, defaultHubStateFile;
import 'package:flutter_agent_harness/src/hub/dap_local_hub_state.dart'
    show parseDapLocalHubState;
import 'package:test/test.dart';

import '../../bin/fah_dap_command.dart' show envHubPidFile;
import '../../bin/fah_hub_serve.dart';

const timeout = Timeout(Duration(seconds: 20));

void main() {
  late Directory tempHome;

  setUp(() async {
    tempHome = await Directory.systemTemp.createTemp('fah-hub-ports-');
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
}
