// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:fa/services/dap_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Behavioral tests for the IO-backed DAP hub service: the save/load
/// round-trip through the machine-shared `~/.dap` layout and the
/// timeout-bounded probe against a dead hub. `HOME` is pointed at a temp
/// dir so the real `~/.dap` is never touched.
void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('fah_dap_service_test');
  });

  tearDown(() {
    home.deleteSync(recursive: true);
  });

  IoDapHubService service() => IoDapHubService(
    environment: {'HOME': home.path, 'USERPROFILE': home.path},
    home: home.path,
    probeTimeout: const Duration(milliseconds: 300),
  );

  test(
    'save then load round-trips the connection and exposes identity',
    () async {
      final svc = service();
      await svc.saveConnection(url: 'hub.example.com:8787', name: 'alice');
      final snapshot = await svc.load();

      expect(snapshot.supported, isTrue);
      // dap_connect host normalization: no scheme, no path → ws://…/ws.
      expect(snapshot.url, 'ws://hub.example.com:8787/ws');
      expect(snapshot.name, 'alice');
      // Identity created 0600 on first use (agentId = 16 hex chars).
      expect(snapshot.agentId, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(File('${home.path}/.dap/keys/fah/alice.key').existsSync(), isTrue);
      expect(snapshot.channels, isEmpty);
      expect(snapshot.envLocked, isFalse);
      expect(snapshot.connected, isNull);
    },
  );

  test('empty name keeps the previously saved name', () async {
    final svc = service();
    await svc.saveConnection(url: 'ws://hub.example.com/ws', name: 'alice');
    await svc.saveConnection(url: 'ws://other.example.com/ws', name: '');
    final snapshot = await svc.load();

    expect(snapshot.url, 'ws://other.example.com/ws');
    expect(snapshot.name, 'alice');
  });

  test('probe against a dead hub reports unreachable, never hangs', () async {
    final snapshot = await service().probe();

    expect(snapshot.connected, isFalse);
    expect(snapshot.supported, isTrue);
  });

  test('env-pinned connection is reported as env-locked', () async {
    final svc = IoDapHubService(
      environment: {
        'HOME': home.path,
        'DAP_HUB_URL': 'ws://pinned.example.com/ws',
      },
      home: home.path,
      probeTimeout: const Duration(milliseconds: 300),
    );

    final snapshot = await svc.load();
    expect(snapshot.envLocked, isTrue);
    expect(snapshot.url, 'ws://pinned.example.com/ws');
  });
}
