// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/icloud_sync_service.dart';

/// Whether the current platform has a native iCloud backend (macOS/iOS).
/// Always false here — this stub is selected where `dart:io` is unavailable
/// (web), so callers degrade to a clean "not supported" note.
bool get icloudSyncSupported => false;

/// Creates the platform [ICloudSyncService]. On web there is no iCloud
/// Drive access, so the service reports itself unavailable and [syncNow] is
/// a no-op error.
ICloudSyncService createICloudSyncService(ExecutionEnv env) =>
    const _UnavailableICloudSyncService();

final class _UnavailableICloudSyncService implements ICloudSyncService {
  const _UnavailableICloudSyncService();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<String?> containerUrl() async => null;

  @override
  Future<ICloudSyncReport> syncNow() =>
      throw StateError('iCloud sync is not supported on this platform.');

  @override
  Future<DateTime?> lastSyncAt() async => null;
}
