// THROWAWAY review probe — not part of the review outputs. Counts blocker
// accepts to determine whether the "closes on first accepted connection"
// retry test actually drives the retry path or attempt 1 binds directly.
import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/io.dart' show LocalHub;
import 'package:test/test.dart';

import '../../bin/fah_dap_command.dart' show envHubPidFile;
import '../../bin/fah_hub_serve.dart';

void main() {
  late Directory tempHome;

  setUp(() async {
    tempHome = await Directory.systemTemp.createTemp('probe-retry-');
  });

  tearDown(() async {
    if (await tempHome.exists()) tempHome.deleteSync(recursive: true);
  });

  test('probe: does the first-accept close free the port before attempt 1?',
      () async {
    final probe = LocalHub(port: 0);
    await probe.start();
    final port = probe.url.port;
    await probe.stop();

    final blocker = await ServerSocket.bind('127.0.0.1', port);
    var accepts = 0;
    final secondConnection = Completer<void>();
    final sub = blocker.listen((socket) {
      accepts++;
      socket.destroy();
      if (accepts == 2 && !secondConnection.isCompleted) {
        secondConnection.complete();
      }
    });
    unawaited(
      secondConnection.future.then((_) async {
        await sub.cancel();
        await blocker.close();
      }),
    );
    addTearDown(() async {
      await sub.cancel();
      await blocker.close();
    });
    final code = await runHubCommand(
      ['serve', '--port', '$port'],
      home: tempHome.path,
      environment: {envHubPidFile: '${tempHome.path}/hub.pid'},
      serveLoop: (hub, _) async => hub.stop(),
    );
    expect(code, 0);
    // accepts == 1 -> pre-probe only; attempt 1 bound directly (retry NOT
    // driven). accepts >= 2 -> attempt 1 failed + probed (retry driven).
    // ignore: avoid_print
    print('PROBE-RESULT: accepts=$accepts (retry '
        '${accepts >= 2 ? 'DRIVEN' : 'NOT driven'})');
  }, timeout: const Timeout(Duration(seconds: 20)));
}
