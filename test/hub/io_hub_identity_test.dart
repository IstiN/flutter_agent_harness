/// The `dart:io` identity file for the app agent's hub address (issue
/// #402 phase 27.1): generate → save → load round-trips the exact seeds,
/// so the agent keeps one stable hub address across restarts.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fah_hub_identity');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('load creates a fresh identity on first boot (load-or-create)', () async {
    final keyPath = '${tmp.path}/absent';
    final created = await loadHubIdentity(keyPath);
    final reloaded = await loadHubIdentity(keyPath);
    expect(reloaded.agentId, created.agentId,
        reason: 'the first boot persists its identity');
  });

  test('a saved identity reloads with the same address', () async {
    final keyPath = '${tmp.path}/hub_identity';
    final first = await HubIdentity.generate();
    await saveHubIdentity(keyPath, first);

    final loaded = await loadHubIdentity(keyPath);
    expect(loaded.agentId, first.agentId);
    expect(
      await loaded.signingKeyPair.extractPrivateKeyBytes(),
      await first.signingKeyPair.extractPrivateKeyBytes(),
    );
    expect(
      await loaded.dhKeyPair.extractPrivateKeyBytes(),
      await first.dhKeyPair.extractPrivateKeyBytes(),
    );
  });


  test('save locks the file to owner-only where the OS supports it', () async {
    final keyPath = '${tmp.path}/hub_identity';
    await saveHubIdentity(keyPath, await HubIdentity.generate());
    if (Platform.isWindows) return; // best-effort by contract
    final mode = FileStat.statSync(keyPath).mode;
    // Owner read/write only: no group/world bits (st_mode format).
    expect(mode & 0x3F, 0, reason: 'private keys must be 0600');
  });
}
