// The `/browser` slash-command surface: pure line-returning functions over
// an injectable handle — a fake handle exercises connect/status output, and
// the absent-handle case answers with a clean note.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Records calls and answers canned sessions/status.
final class _FakeHandle implements BrowserBridgeHandle {
  _FakeHandle({this.failConnect});

  final Object? failConnect;
  var connectCalls = 0;
  var lastPort = 0;
  var statusCalls = 0;

  @override
  Future<BrowserBridgeSession> connect({int port = bridgeDefaultPort}) async {
    if (failConnect != null) throw failConnect!;
    connectCalls++;
    lastPort = port;
    return BrowserBridgeSession(
      url: 'ws://127.0.0.1:$port/ws',
      token: 'f' * 64,
      alreadyRunning: connectCalls > 1,
    );
  }

  @override
  Future<BrowserBridgeStatus> status() async {
    statusCalls++;
    return const BrowserBridgeStatus(
      running: true,
      url: 'ws://127.0.0.1:8777/ws',
      extensions: ['browser-ext/e1'],
      mailboxes: [
        (id: 'main', cwd: '/work/proj'),
        (id: 'browser-ext/e1', cwd: null),
      ],
    );
  }
}

void main() {
  group('/browser connect', () {
    test(
      'prints the ws URL, the one-time token and the mailbox hint',
      () async {
        final handle = _FakeHandle();
        final lines = await runBrowserCommand(handle, '');
        expect(handle.connectCalls, 1);
        expect(handle.lastPort, bridgeDefaultPort);
        expect(
          lines.join('\n'),
          allOf(
            contains('ws://127.0.0.1:8777/ws'),
            contains('f' * 64),
            contains('browser-ext/<agentId>'),
          ),
        );
      },
    );

    test('a port argument is passed through', () async {
      final handle = _FakeHandle();
      await runBrowserCommand(handle, 'connect 9000');
      expect(handle.lastPort, 9000);
    });

    test('a non-numeric port is refused without touching the handle', () async {
      final handle = _FakeHandle();
      final lines = await runBrowserCommand(handle, 'connect abc');
      expect(handle.connectCalls, 0);
      expect(lines.join('\n'), contains('not a port: abc'));
    });

    test('a connect failure surfaces the error line', () async {
      final handle = _FakeHandle(failConnect: StateError('port busy'));
      final lines = await runBrowserCommand(handle, 'connect');
      expect(lines.join('\n'), contains('port busy'));
    });

    test('connect start alias behaves like connect', () async {
      final handle = _FakeHandle();
      final lines = await runBrowserCommand(handle, 'start');
      expect(handle.connectCalls, 1);
      expect(lines.join('\n'), contains('started'));
    });
  });

  group('/browser status', () {
    test('shows connected extensions and the fabric mailboxes', () async {
      final handle = _FakeHandle();
      final lines = await runBrowserCommand(handle, 'status');
      expect(handle.statusCalls, 1);
      final output = lines.join('\n');
      expect(output, contains('running on ws://127.0.0.1:8777/ws'));
      expect(output, contains('browser-ext/e1'));
      expect(output, contains('main — /work/proj'));
      expect(output, contains('browser-ext/e1'), reason: 'mailbox listed');
    });
  });

  group('without a handle', () {
    test('connect answers with a clean unavailable note', () async {
      final lines = await runBrowserCommand(null, '');
      expect(lines, hasLength(1));
      expect(lines.single, contains('not available'));
    });

    test('status answers with the same note', () async {
      final lines = await runBrowserCommand(null, 'status');
      expect(lines.single, contains('not available'));
    });
  });

  test('an unknown subcommand gets the usage line', () async {
    final lines = await runBrowserCommand(_FakeHandle(), 'wat');
    expect(lines.join('\n'), contains('unknown subcommand: wat'));
    expect(lines.join('\n'), contains('usage: /browser'));
  });
}
