// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/browser/bridge_protocol.dart';
import 'package:flutter_agent_harness/src/cli/browser_bridge_commands.dart';
import 'package:test/test.dart';

final class _FakeBridge implements BrowserBridgeHandle {
  _FakeBridge({this.session, this.statusResult, this.connectError});

  BrowserBridgeSession? session;
  BrowserBridgeStatus? statusResult;
  Object? connectError;

  int connectCalls = 0;
  int? seenPort;
  bool? seenCopyKeys;

  @override
  Future<BrowserBridgeSession> connect({
    int port = bridgeDefaultPort,
    bool copyKeys = false,
  }) async {
    connectCalls++;
    seenPort = port;
    seenCopyKeys = copyKeys;
    final error = connectError;
    if (error != null) throw error;
    return session!;
  }

  @override
  Future<BrowserBridgeStatus> status() async => statusResult!;
}

void main() {
  group('runBrowserCommand', () {
    test(
      'a null handle answers the unavailable note for every subcommand',
      () async {
        final note = contains('not available on this host');
        expect(await runBrowserCommand(null, ''), hasLength(1));
        expect(await runBrowserCommand(null, 'connect'), everyElement(note));
        expect(await runBrowserCommand(null, 'status'), everyElement(note));
      },
    );

    test('an unknown subcommand names it and prints usage', () async {
      final lines = await runBrowserCommand(null, 'bogus');
      expect(lines.first, 'bridge: unknown subcommand: bogus');
      expect(lines.last, contains('usage: /browser'));
    });

    test('a non-numeric port is refused before any connect', () async {
      final handle = _FakeBridge();
      final lines = await runBrowserCommand(handle, 'connect nope');
      expect(lines.first, 'bridge: not a port: nope');
      expect(lines, hasLength(2));
      expect(handle.connectCalls, 0);
    });

    test('bare connect starts the bridge: ws url, token, pair hint', () async {
      final handle = _FakeBridge(
        session: const BrowserBridgeSession(
          url: 'ws://127.0.0.1:8777/ws',
          token: 'abc123',
          alreadyRunning: false,
        ),
      );
      final lines = await runBrowserCommand(handle, '');
      expect(lines[0], 'bridge: started on ws://127.0.0.1:8777/ws');
      expect(
        lines[1],
        contains('token (one-time — old tokens are invalid): abc123'),
      );
      expect(lines[2], contains('pair as: browser-ext/<agentId>'));
      expect(lines.where((l) => l.startsWith('keys:')), isEmpty);
      expect(handle.seenPort, bridgeDefaultPort);
      expect(handle.seenCopyKeys, isFalse);
    });

    test('an already-running bridge reports reuse, not start', () async {
      final handle = _FakeBridge(
        session: const BrowserBridgeSession(
          url: 'ws://127.0.0.1:9000/ws',
          token: 't',
          alreadyRunning: true,
        ),
      );
      expect(
        (await runBrowserCommand(handle, 'start')).first,
        'bridge: already running on ws://127.0.0.1:9000/ws',
      );
    });

    test(
      '--copy-keys reaches the handle and adds the copy-on-pair line',
      () async {
        final handle = _FakeBridge(
          session: const BrowserBridgeSession(
            url: 'ws://127.0.0.1:8777/ws',
            token: 't',
            alreadyRunning: false,
          ),
        );
        final lines = await runBrowserCommand(handle, 'connect --copy-keys');
        expect(handle.seenCopyKeys, isTrue);
        expect(lines.last, contains('keys: copy-on-pair'));
      },
    );

    test('an explicit port reaches the handle verbatim', () async {
      final handle = _FakeBridge(
        session: const BrowserBridgeSession(
          url: 'ws://127.0.0.1:9999/ws',
          token: 't',
          alreadyRunning: false,
        ),
      );
      await runBrowserCommand(handle, 'connect 9999');
      expect(handle.seenPort, 9999);
    });

    test(
      'a throwing connect surfaces the error as a line, not a crash',
      () async {
        final handle = _FakeBridge(connectError: Exception('port busy'));
        final lines = await runBrowserCommand(handle, 'connect');
        expect(lines, ['bridge: Exception: port busy']);
      },
    );
  });

  group('/browser status', () {
    test('not running: says so and lists no extensions', () async {
      final handle = _FakeBridge(
        statusResult: const BrowserBridgeStatus(
          running: false,
          url: null,
          extensions: [],
          mailboxes: [],
        ),
      );
      final lines = await runBrowserCommand(handle, 'status');
      expect(lines[0], 'bridge: not running — /browser connect starts it');
      expect(lines[1], 'extensions: none connected');
      expect(lines[2], 'mailboxes:');
    });

    test('running: endpoint, extensions, and mailboxes with cwd', () async {
      final handle = _FakeBridge(
        statusResult: const BrowserBridgeStatus(
          running: true,
          url: 'ws://127.0.0.1:8777/ws',
          extensions: ['ext-a', 'ext-b'],
          mailboxes: [(id: 'mb-1', cwd: '/tmp/work'), (id: 'mb-2', cwd: null)],
        ),
      );
      final lines = await runBrowserCommand(handle, 'status');
      expect(lines[0], 'bridge: running on ws://127.0.0.1:8777/ws');
      expect(lines[1], 'extensions: ext-a, ext-b');
      expect(lines[3], '  mb-1 — /tmp/work');
      expect(lines[4], '  mb-2'); // no cwd, no dangling separator
    });
  });
}
