// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:flutter/services.dart';

import 'package:fa/services/health_service.dart';

/// Whether the current platform has a native health backend: HealthKit is
/// wired up on iOS and macOS 14+ (see `AppDelegate.swift` /
/// `HealthChannel.swift`).
bool get healthPlatformSupported => Platform.isIOS || Platform.isMacOS;

/// Creates the method-channel-backed [HealthApi] (IO platforms).
HealthApi createHealthService() => const MethodChannelHealthApi();

/// [HealthApi] over the `fah/health` method channel.
final class MethodChannelHealthApi implements HealthApi {
  const MethodChannelHealthApi();

  static const _channel = MethodChannel('fah/health');

  @override
  Future<bool> get isAvailable async => healthPlatformSupported;

  @override
  Future<bool> requestAccess() async {
    if (!healthPlatformSupported) return false;
    try {
      final granted = await _channel.invokeMethod<bool>('requestAccess');
      return granted ?? false;
    } on MissingPluginException {
      // No native handler (e.g. unit tests) — treat as denied.
      return false;
    }
  }

  @override
  Future<HealthSummary> summary({required int days}) async {
    if (!healthPlatformSupported) throw _unsupported();
    final Map<dynamic, dynamic>? raw;
    try {
      raw = await _channel.invokeMapMethod<dynamic, dynamic>('summary', {
        'days': days,
      });
    } on MissingPluginException {
      throw _unsupported();
    }
    List<HealthSample> samplesOf(String key) => [
      for (final entry in (raw?[key] as List?) ?? const [])
        if (entry is Map)
          (
            date: entry['date']?.toString() ?? '',
            value: (entry['value'] as num?)?.toDouble() ?? 0,
          ),
    ];
    return (
      steps: samplesOf('steps'),
      restingHeartRate: samplesOf('restingHeartRate'),
      sleepHours: samplesOf('sleepHours'),
    );
  }

  static StateError _unsupported() =>
      StateError('Health data is not supported on this platform.');
}
