// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:fa/services/dap_service.dart' show DapInboundMode;
import 'package:fa/services/dap_service_io.dart';
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

  test('save persists the hub password; empty keeps it', () async {
    final svc = service();
    await svc.saveConnection(
      url: 'ws://hub.example.com/ws',
      name: 'alice',
      secret: 'pw1',
    );
    final config =
        jsonDecode(File('${home.path}/.dap/config.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(config['client' + 'Secret'], 'pw1');
    // An empty field keeps whatever is stored.
    await svc.saveConnection(url: 'ws://hub.example.com/ws', name: 'alice');
    final kept =
        jsonDecode(File('${home.path}/.dap/config.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(kept['client' + 'Secret'], 'pw1');
  });

  test('empty name keeps the previously saved name', () async {
    final svc = service();
    await svc.saveConnection(url: 'ws://hub.example.com/ws', name: 'alice');
    await svc.saveConnection(url: 'ws://other.example.com/ws', name: '');
    final snapshot = await svc.load();

    expect(snapshot.url, 'ws://other.example.com/ws');
    expect(snapshot.name, 'alice');
  });

  test('probe against a dead hub reports unreachable, never hangs', () async {
    // A port nothing listens on — the default 8787 would race a real dev
    // hub running on this machine.
    final svc = IoDapHubService(
      environment: {'HOME': home.path, 'DAP_HUB_URL': 'ws://127.0.0.1:1/ws'},
      home: home.path,
      probeTimeout: const Duration(milliseconds: 300),
    );
    final snapshot = await svc.probe();

    expect(snapshot.connected, isFalse);
    expect(snapshot.supported, isTrue);
  });

  group('inbound binding', () {
    test('saveBinding writes boundSession; load maps it back', () async {
      final svc = service();
      await svc.saveConnection(url: 'hub.example.com:8787', name: 'alice');
      await svc.saveBinding(
        DapInboundMode.named,
        sessionId: 'sess-1',
        sessionTitle: 'My session',
      );
      final snapshot = await svc.load();
      expect(snapshot.inboundMode, DapInboundMode.named);
      expect(snapshot.boundSessionId, 'sess-1');
      expect(snapshot.boundSessionTitle, 'My session');
    });

    test('currentSession mode removes the boundSession block', () async {
      final svc = service();
      await svc.saveConnection(url: 'hub.example.com:8787', name: 'alice');
      await svc.saveBinding(DapInboundMode.dedicated);
      var snapshot = await svc.load();
      expect(snapshot.inboundMode, DapInboundMode.dedicated);
      await svc.saveBinding(DapInboundMode.currentSession);
      snapshot = await svc.load();
      expect(snapshot.inboundMode, DapInboundMode.currentSession);
      expect(snapshot.boundSessionId, isNull);
      // The connection itself survives binding edits.
      expect(snapshot.url, 'ws://hub.example.com:8787/ws');
      expect(snapshot.name, 'alice');
    });

    test('a missing config reports the zero-config default mode', () async {
      final snapshot = await service().load();
      expect(snapshot.inboundMode, DapInboundMode.currentSession);
    });
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
