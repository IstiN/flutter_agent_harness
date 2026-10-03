/// E2E for the one-step local DAP hub (issue #304): the REAL CLI binary
/// (`dart bin/fah.dart dap start/stop/status`) against a REAL spawned hub
/// process, with a second `fa_hub_client` instance playing the browser
/// extension — zero config, zero env beyond an isolated HOME (AC5). The
/// spawned hub is on an ephemeral port so the suite never touches the
/// machine's zero-config 8787.
@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart' as client;
import 'package:flutter_agent_harness/io.dart' show LocalHub;
import 'package:flutter_agent_harness/src/hub/dap_local_hub_state.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempHome;
  late int port;

  setUp(() async {
    tempHome = await Directory.systemTemp.createTemp('fah-dap-e2e-');
    // A free loopback port (bind-close dance).
    final probe = LocalHub(port: 0);
    await probe.start();
    port = probe.url.port;
    await probe.stop();
  });

  tearDown(() async {
    // Safety net: never leak a detached hub past the test.
    final pidFile = File(dapHubPidFileFor(tempHome.path));
    final state = parseDapLocalHubState(
      await pidFile.exists() ? pidFile.readAsStringSync() : null,
    );
    if (state != null) {
      Process.killPid(state.pid, ProcessSignal.sigterm);
    }
    if (await tempHome.exists()) {
      tempHome.deleteSync(recursive: true);
    }
  });

  Map<String, String> envOf() => {
    ...Platform.environment,
    'HOME': tempHome.path,
    // Keep every DAP artifact inside the temp HOME.
    'DAP_HUB_PID_FILE': dapHubPidFileFor(tempHome.path),
  };

  Future<ProcessResult> fa(List<String> args) => Process.run(
    'dart',
    ['bin/fah.dart', 'dap', ...args],
    workingDirectory: Directory.current.path,
    environment: envOf(),
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  ).timeout(const Duration(seconds: 90));

  Future<bool> healthz() async {
    try {
      final http = HttpClient()..connectionTimeout = const Duration(seconds: 1);
      final response = await (await http.get(
        '127.0.0.1',
        port,
        '/healthz',
      )).close();
      await response.drain<void>();
      http.close();
      return response.statusCode == 200;
    } on Object {
      return false;
    }
  }

  test(
    'E2E-start + E2E-endtoend + IT-stop: start, zero-config extension '
    'join, DM round-trip via the persisted credential, status, stop',
    () async {
      // ---- fa dap start (non-interactive pipe: open hub, no prompts) --
      final start = await fa(['start', '--port', '$port']);
      final startOut = '${start.stdout}${start.stderr}';
      expect(start.exitCode, 0, reason: startOut);
      expect(startOut, contains('DAP hub on ws://127.0.0.1:$port/ws'));
      expect(startOut, contains('enrolled'), reason: 'clientSecret persisted');
      expect(startOut, contains('fabric enabled'));
      expect(await healthz(), isTrue);

      // The state contract (AC1): clientSecret 0600 in ~/.dap/config.json,
      // pid state under ~/.dap/, identity key under ~/.dap/keys/fah/.
      final config = client.readDapConfig(
        client.defaultDapConfigFile(tempHome.path, envOf()),
      );
      expect(config['clientSecret'], isA<String>());
      expect(config['url'], 'ws://127.0.0.1:$port/ws');
      final pidState = parseDapLocalHubState(
        File(dapHubPidFileFor(tempHome.path)).readAsStringSync(),
      );
      expect(pidState, isNotNull);
      expect(pidState!.port, port);
      expect(
        Directory('${tempHome.path}/.dap/keys/fah').listSync(),
        isNotEmpty,
      );

      // ---- the extension: a second fa_hub_client joins ZERO-CONFIG -----
      final browser = client.HubClient(
        config: client.HubConfig(
          url: 'ws://127.0.0.1:$port/ws',
          name: 'Browser',
        ),
        identity: await client.HubIdentity.generate(),
      );
      await browser.connect();
      addTearDown(browser.disconnect);

      // ---- the CLI's own agent: the persisted credential + identity ---
      final settings = client.resolveDapSettings(
        config: client.HubConfig(url: 'ws://127.0.0.1:$port/ws'),
        environment: envOf(),
        home: tempHome.path,
      );
      final self = client.HubClient(
        config: client.HubConfig(url: 'ws://127.0.0.1:$port/ws'),
        identity: await client.HubIdentity.load(settings.keyPath),
        clientSecret: config['clientSecret'] as String,
      );
      await self.connect();
      addTearDown(self.disconnect);

      // DM round-trip both ways over the real transport (AC4/E2E).
      await browser.sendDm(self.agentId!, 'e2e hello');
      final inbound = await self.inbound
          .firstWhere((m) => m.plaintext == 'e2e hello')
          .timeout(const Duration(seconds: 5));
      expect(inbound.from, browser.agentId);

      // ---- fa dap status sees the hub and names the peer --------------
      final status = await fa(['status', '--port', '$port']);
      final statusOut = '${status.stdout}${status.stderr}';
      expect(status.exitCode, 0, reason: statusOut);
      expect(statusOut, contains('running'));
      expect(statusOut, contains('Browser'));

      // ---- fa dap stop warns about the peer and stops (AC2/E4) --------
      final stop = await fa(['stop', '--port', '$port']);
      final stopOut = '${stop.stdout}${stop.stderr}';
      expect(stop.exitCode, 0, reason: stopOut);
      expect(stopOut, contains('Browser'),
          reason: 'the stop warning names the connected extension peer');
      expect(stopOut, contains('DAP hub stopped'));
      expect(await healthz(), isFalse);
      expect(await File(dapHubPidFileFor(tempHome.path)).exists(), isFalse,
          reason: 'no zombie pid state (E4)');

      // Second stop: calm no-op.
      final stop2 = await fa(['stop', '--port', '$port']);
      expect(stop2.exitCode, 0);
      expect('${stop2.stdout}${stop2.stderr}', contains('not running'));
    },
  );
}
