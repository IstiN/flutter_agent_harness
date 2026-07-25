// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/icloud_sync_service.dart';
import 'package:fa/services/icloud_sync_tool.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Configurable fake [ICloudSyncService] — the host-side tests never touch
/// the real method channel.
final class FakeICloudSyncService implements ICloudSyncService {
  FakeICloudSyncService({this.available = true, this.report});

  bool available;
  ICloudSyncReport? report;
  int syncCalls = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<String?> containerUrl() async =>
      available ? '/fake/container/Documents' : null;

  @override
  Future<ICloudSyncReport> syncNow() async {
    syncCalls++;
    final value = report;
    if (value == null) throw StateError('no report configured');
    return value;
  }

  @override
  Future<DateTime?> lastSyncAt() async => report?.syncedAt;
}

String _textOf(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join();

Future<String> _run(AgentTool tool) async =>
    _textOf(await tool.execute(const {}, null, null));

void main() {
  group('icloudSyncTool', () {
    test('is a write-tier tool', () {
      expect(icloudSyncTool(FakeICloudSyncService()).tier, ApprovalTier.write);
    });

    test('renders the synced counts and last-sync timestamp', () async {
      final service = FakeICloudSyncService(
        report: (
          filesCopied: 3,
          bytesCopied: 2048,
          syncedAt: DateTime(2026, 7, 25, 19, 12),
        ),
      );

      final text = await _run(icloudSyncTool(service));

      expect(service.syncCalls, 1);
      expect(text, 'Synced 3 files (2 KB) — last sync 2026-07-25 19:12.');
    });

    test('renders the unavailable guidance and never syncs', () async {
      final service = FakeICloudSyncService(available: false);

      final text = await _run(icloudSyncTool(service));

      expect(service.syncCalls, 0);
      expect(text, contains('Settings → Apple ID → iCloud'));
      expect(text, contains('iCloud.dev.fa1.app'));
      expect(text, contains('provisioning profile'));
    });
  });

  group('formatICloudSyncReport', () {
    test('rounds sub-KB copies to 0 KB', () {
      final text = formatICloudSyncReport((
        filesCopied: 1,
        bytesCopied: 400,
        syncedAt: DateTime(2026, 1, 2, 3, 4),
      ));
      expect(text, 'Synced 1 files (0 KB) — last sync 2026-01-02 03:04.');
    });
  });
}
