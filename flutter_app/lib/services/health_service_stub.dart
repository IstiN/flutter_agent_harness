// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/health_service.dart';

/// Whether the current platform has a native health backend (iOS HealthKit).
/// Always false here — this stub is selected where `dart:io` is unavailable
/// (web), so callers degrade to a clean "not supported" note.
bool get healthPlatformSupported => false;

/// Creates the platform [HealthApi]. On web there is no health-data backend,
/// so the service reports itself unavailable and every call is a no-op.
HealthApi createHealthService() => const _UnavailableHealthApi();

final class _UnavailableHealthApi implements HealthApi {
  const _UnavailableHealthApi();

  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<bool> requestAccess() async => false;

  @override
  Future<HealthSummary> summary({required int days}) =>
      throw StateError('Health data is not supported on this platform.');
}
