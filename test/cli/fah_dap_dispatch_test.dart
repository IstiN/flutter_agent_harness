/// UT for the `fa dap` CLI dispatch (issue #304): flag parsing
/// ([parseDapInvocation]), the verb table ([dapSubcommands]), and the
/// seams flowing into [DapHubController] through `runDapCommand` —
/// the CRAP-ratchet coverage for the split dispatcher. The controller
/// itself is covered by `test/hub/dap_command_test.dart`; the
/// real-process E2E lives in `test/integration/dap_cli_e2e_test.dart`.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_harness/io.dart'
    show LocalHub, defaultHubStateFile;
import 'package:test/test.dart';

import '../../bin/fah_dap_command.dart';

const timeout = Timeout(Duration(seconds: 20));

void main() {
  late Directory tempHome;

  setUp(() async {
    tempHome = await Directory.systemTemp.createTemp('fah-dap-cli-');
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

  group('dapPortUrl', () {
    test('a valid port becomes the loopback ws url', () {
      expect(dapPortUrl('9000'), 'ws://127.0.0.1:9000/ws');
    });

    test('missing, non-numeric, and non-positive values are rejected', () {
      expect(dapPortUrl(null), isNull);
      expect(dapPortUrl('nope'), isNull);
      expect(dapPortUrl('0'), isNull);
      expect(dapPortUrl('-1'), isNull);
    });
  });

  group('parseDapInvocation', () {
    test('no flags: the zero-config default, not explicit', () {
      expect(parseDapInvocation(const []), (
        url: defaultDapLocalHubUrl,
        explicit: false,
      ));
    });

    test('--port and --url are explicit; the last one wins', () {
      expect(parseDapInvocation(const ['--port', '9100']), (
        url: 'ws://127.0.0.1:9100/ws',
        explicit: true,
      ));
      expect(
        parseDapInvocation(const ['--port', '9100', '--url', 'ws://x/ws']),
        (url: 'ws://x/ws', explicit: true),
      );
    });

    test('a bad flag or a missing value rejects the invocation', () {
      expect(parseDapInvocation(const ['--port', 'x']), isNull);
      expect(parseDapInvocation(const ['--port']), isNull);
      expect(parseDapInvocation(const ['--url']), isNull);
      expect(parseDapInvocation(const ['--wat', 'x']), isNull);
      expect(parseDapInvocation(const ['positional']), isNull);
    });
  });

  group('runDapCommand dispatch', () {
    test('no verb: usage, exit 1', () async {
      expect(
        await runDapCommand(
          const [],
          home: tempHome.path,
          environment: const {},
        ),
        1,
      );
    });

    test('unknown verb: usage, exit 1', () async {
      expect(
        await runDapCommand(
          const ['explode'],
          home: tempHome.path,
          environment: const {},
        ),
        1,
      );
    });

    test('bad flags after a known verb: usage, exit 1', () async {
      expect(
        await runDapCommand(
          const ['status', '--port', 'NaN'],
          home: tempHome.path,
          environment: const {},
        ),
        1,
      );
      expect(
        await runDapCommand(
          const ['start', 'extra'],
          home: tempHome.path,
          environment: const {},
        ),
        1,
      );
    });

    test('status on a dead port: exit 0, "not running"', () async {
      final port = await freePort();
      final lines = <String>[];
      final code = await runDapCommand(
        ['status', '--port', '$port'],
        home: tempHome.path,
        environment: const {},
        out: lines.add,
      );
      expect(code, 0);
      expect(lines.join('\n'), contains('DAP hub: not running'));
    });

    test('status against a live hub: exit 0, running line', () async {
      final port = await freePort();
      final hub = LocalHub(port: port, stateFile: stateFileFor());
      await hub.start();
      addTearDown(() => hub.stop());
      final lines = <String>[];
      final code = await runDapCommand(
        ['status', '--url', hub.url.toString()],
        home: tempHome.path,
        environment: const {},
        out: lines.add,
      );
      expect(code, 0);
      expect(lines.join('\n'), contains('running at ${hub.url}'));
    });

    test('start: prompt + spawn seams flow through, hub up, exit 0', () async {
      final port = await freePort();
      final hub = LocalHub(port: port, stateFile: stateFileFor());
      addTearDown(() => hub.stop());
      final lines = <String>[];
      final code = await runDapCommand(
        ['start', '--port', '$port'],
        home: tempHome.path,
        environment: const {},
        spawnHub: (url, masterSecret) async {
          await hub.start();
          return 1; // the in-process stand-in pid
        },
        secretPrompt: (_) async => 'k1-master-key',
        out: lines.add,
      );
      expect(code, 0, reason: lines.join('\n'));
      expect(lines.join('\n'), contains('DAP hub on ws://127.0.0.1:$port'));
    }, timeout: timeout);

    test('stop with no hub running: exit 0, calm no-op', () async {
      final port = await freePort();
      final lines = <String>[];
      final code = await runDapCommand(
        ['stop', '--port', '$port'],
        home: tempHome.path,
        environment: const {},
        terminateHub: (_) async => true,
        out: lines.add,
      );
      expect(code, 0);
      expect(lines.join('\n'), contains('DAP hub is not running'));
    });
  });

  test(
    'buildDapController: DAP_LOCAL_HUB_URL wins unless a flag set the url',
    () {
      final env = {envLocalHubUrl: 'ws://127.0.0.1:9500/ws'};
      final fromEnv = buildDapController(
        (url: defaultDapLocalHubUrl, explicit: false),
        home: tempHome.path,
        environment: env,
      );
      expect(fromEnv.url, 'ws://127.0.0.1:9500/ws');
      final fromFlag = buildDapController(
        (url: 'ws://127.0.0.1:9600/ws', explicit: true),
        home: tempHome.path,
        environment: env,
      );
      expect(fromFlag.url, 'ws://127.0.0.1:9600/ws');
    },
  );
}
