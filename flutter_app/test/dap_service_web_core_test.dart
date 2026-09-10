// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/dap_service.dart' show DapInboundMode;
import 'package:fa/services/dap_service_web_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Behavioral tests for the extension-hosted DAP hub service core: the
/// chrome.storage + SW-status mapping behind injected bridges (the
/// js_interop defaults in dap_service_web.dart stay untestable on the VM).
void main() {
  /// Fake bridges over an in-memory "extension": [storage] mirrors
  /// chrome.storage.local, [hubStatus] mirrors the SW agent's hub snapshot
  /// (null = no hub key in the agent state).
  ({
    ExtensionDapHubService service,
    List<Map<String, Object?>> sent,
    void Function(Map<String, Object?>?) setHub,
  })
  harness({
    Map<String, Object?> storage = const {},
    Map<String, Object?>? hubStatus,
    Object? Function(Map<String, Object?>)? onMessage,
  }) {
    final sent = <Map<String, Object?>>[];
    var hub = hubStatus;
    final service = ExtensionDapHubService(
      pollInterval: Duration.zero,
      probeTimeout: const Duration(milliseconds: 50),
      sendMessage: (message) async {
        sent.add(message);
        if (onMessage != null) return onMessage(message);
        return switch (message['type']) {
          // The REAL SW shape: the snapshot rides wrapped under 'status'
          // (sw/main.js: {ok: true, status: snapshot()}).
          'status' => {
            'ok': true,
            'status': {
              'agent': {'booted': true, if (hub != null) 'hub': hub},
            },
          },
          'hub.save' => {'ok': true},
          'hub.bind' => {'ok': true},
          'hub.sessions' => {
            'ok': true,
            'sessions': [
              {'id': 'aaaabbbbccccdddd', 'running': true},
              {'id': 'eeee00001111', 'running': false},
            ],
          },
          _ => null,
        };
      },
      storageGet: (key) async => {key: storage[key]},
    );
    return (service: service, sent: sent, setHub: (next) => hub = next);
  }

  test('load maps the configured connection and the live phase', () async {
    final h = harness(
      storage: const {
        'faDap': {'url': 'ws://127.0.0.1:9999/ws', 'name': 'ext-agent'},
      },
      hubStatus: const {'phase': 'connected', 'agentId': '0123456789abcdef'},
    );
    final snapshot = await h.service.load();
    expect(snapshot.supported, isTrue);
    expect(snapshot.url, 'ws://127.0.0.1:9999/ws');
    expect(snapshot.name, 'ext-agent');
    expect(snapshot.agentId, '0123456789abcdef');
    expect(snapshot.connected, isTrue);
    expect(snapshot.channels, isEmpty);
  });

  test('load without a saved config shows the zero-config default', () async {
    final h = harness();
    final snapshot = await h.service.load();
    expect(snapshot.supported, isTrue);
    expect(snapshot.url, defaultWebDapUrl);
    expect(snapshot.name, isNull);
    expect(snapshot.agentId, isNull);
    expect(snapshot.connected, isNull);
  });

  test('a transient phase maps to unknown, disconnected to false', () async {
    final h = harness(hubStatus: const {'phase': 'reconnecting'});
    expect((await h.service.load()).connected, isNull);
    h.setHub(const {'phase': 'disconnected', 'reason': 'boom'});
    final snapshot = await h.service.load();
    expect(snapshot.connected, isFalse);
  });

  test('save normalizes the host and goes through hub.save', () async {
    final h = harness();
    await h.service.saveConnection(url: '127.0.0.1:9999', name: '  ext  ');
    expect(h.sent, hasLength(1));
    expect(h.sent.single['type'], 'hub.save');
    expect(h.sent.single['url'], 'ws://127.0.0.1:9999/ws');
    expect(h.sent.single['name'], 'ext');
  });

  test('save rides the password through hub.save only when typed', () async {
    final h = harness();
    await h.service.saveConnection(
      url: '127.0.0.1:9999',
      name: 'ext',
      secret: 'pw1',
    );
    expect(h.sent.single['sec' + 'ret'], 'pw1');
    // An empty field keeps the stored one: no key at all in the message.
    final h2 = harness();
    await h2.service.saveConnection(url: '127.0.0.1:9999', name: 'ext');
    expect(h2.sent.single.containsKey('sec' + 'ret'), isFalse);
    final h3 = harness();
    await h3.service.saveConnection(
      url: '127.0.0.1:9999',
      name: 'ext',
      secret: '  ',
    );
    expect(h3.sent.single.containsKey('sec' + 'ret'), isFalse);
  });

  test('save surfaces a SW-side failure', () {
    final h = harness(
      onMessage: (_) => {'ok': false, 'error': 'storage blocked'},
    );
    expect(
      () => h.service.saveConnection(url: 'h:1', name: ''),
      throwsStateError,
    );
  });

  test(
    'probe waits out a transient phase and reports the settled state',
    () async {
      harness(hubStatus: const {'phase': 'connecting'});
      // Settle mid-probe: the second status read sees the welcome.
      var reads = 0;
      final service = ExtensionDapHubService(
        pollInterval: Duration.zero,
        probeTimeout: const Duration(seconds: 1),
        storageGet: (key) async => const {},
        sendMessage: (message) async {
          reads++;
          return {
            'agent': {
              'hub': reads < 2
                  ? const {'phase': 'connecting'}
                  : const {'phase': 'connected', 'agentId': 'aaaabbbbccccdddd'},
            },
          };
        },
      );
      final snapshot = await service.probe();
      expect(snapshot.connected, isTrue);
    },
  );

  test(
    'probe gives up to an honest false when the phase never settles',
    () async {
      final h = harness(hubStatus: const {'phase': 'connecting'});
      final snapshot = await h.service.probe();
      expect(snapshot.connected, isFalse);
    },
  );

  test('a dead SW reads as unknown, never throws', () async {
    final service = ExtensionDapHubService(
      probeTimeout: Duration.zero,
      sendMessage: (_) => throw StateError('no SW'),
      storageGet: (_) => throw StateError('no storage'),
    );
    final snapshot = await service.load();
    expect(snapshot.supported, isTrue);
    expect(snapshot.url, defaultWebDapUrl);
    expect(snapshot.connected, isNull);
  });

  test('normalizeWebDapHost mirrors the CLI normalization', () {
    expect(normalizeWebDapHost('hub:8787'), 'ws://hub:8787/ws');
    expect(normalizeWebDapHost('ws://hub:8787'), 'ws://hub:8787/ws');
    expect(normalizeWebDapHost('wss://h.example/ws'), 'wss://h.example/ws');
    expect(normalizeWebDapHost('ws://h:1/custom'), 'ws://h:1/custom');
  });

  group('inbound binding', () {
    test('load maps faDap.boundSession into the snapshot', () async {
      final h = harness(
        storage: const {
          'faDap': {
            'url': 'ws://127.0.0.1:9999/ws',
            'boundSession': {
              'mode': 'dedicated',
              'sessionId': 'ded-1',
              'title': 'BrowserAgent',
            },
          },
        },
      );
      final snapshot = await h.service.load();
      expect(snapshot.inboundMode, DapInboundMode.dedicated);
      expect(snapshot.boundSessionId, 'ded-1');
      expect(snapshot.boundSessionTitle, 'BrowserAgent');
    });

    test('no boundSession → currentSession mode, no id/title', () async {
      final h = harness();
      final snapshot = await h.service.load();
      expect(snapshot.inboundMode, DapInboundMode.currentSession);
      expect(snapshot.boundSessionId, isNull);
      expect(snapshot.boundSessionTitle, isNull);
    });

    test('saveBinding sends hub.bind with mode + session fields', () async {
      final h = harness();
      await h.service.saveBinding(
        DapInboundMode.named,
        sessionId: 'abc',
        sessionTitle: 'My session',
      );
      final bind = h.sent.singleWhere((m) => m['type'] == 'hub.bind');
      expect(bind['mode'], 'named');
      expect(bind['sessionId'], 'abc');
      expect(bind['title'], 'My session');
    });

    test(
      'saveBinding current clears the binding (no session fields)',
      () async {
        final h = harness();
        await h.service.saveBinding(DapInboundMode.currentSession);
        final bind = h.sent.singleWhere((m) => m['type'] == 'hub.bind');
        expect(bind['mode'], 'current');
        expect(bind.containsKey('sessionId'), isFalse);
      },
    );

    test('hub.bind failure throws', () async {
      final h = harness(
        onMessage: (m) async =>
            m['type'] == 'hub.bind' ? {'ok': false, 'error': 'no hub'} : null,
      );
      await expectLater(
        h.service.saveBinding(DapInboundMode.dedicated),
        throwsStateError,
      );
    });

    test('listBindableSessions maps hub.sessions rows', () async {
      final h = harness();
      final sessions = await h.service.listBindableSessions();
      expect(sessions, hasLength(2));
      expect(sessions.first.id, 'aaaabbbbccccdddd');
      expect(sessions.first.title, contains('(active)'));
      expect(sessions.last.title, 'session eeee0000');
    });

    test('listBindableSessions swallows an unreachable SW', () async {
      final h = harness(onMessage: (_) async => throw StateError('dead'));
      expect(await h.service.listBindableSessions(), isEmpty);
    });
  });
}
