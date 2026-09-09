// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

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
          'status' => {
            'agent': {'booted': true, if (hub != null) 'hub': hub},
          },
          'hub.save' => {'ok': true},
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
}
