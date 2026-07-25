// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

export 'package:fa/services/health_service_stub.dart'
    if (dart.library.io) 'package:fa/services/health_service_io.dart';

/// One per-day health data point: [date] is the local day (YYYY-MM-DD) the
/// value belongs to — a sleep night is attributed to the morning it ends on.
typedef HealthSample = ({String date, double value});

/// A health summary over a span of days: daily step counts, resting heart
/// rate averages (bpm), and asleep hours per night. Days without data are
/// omitted from each series.
typedef HealthSummary = ({
  List<HealthSample> steps,
  List<HealthSample> restingHeartRate,
  List<HealthSample> sleepHours,
});

/// Read-only access to the user's health data (HealthKit on iOS — there is
/// no HealthKit on macOS, and no equivalent on the other platforms).
///
/// Use [createHealthService] (conditionally imported above) to obtain the
/// platform implementation: the `fah/health` method channel on IO
/// platforms, a never-available stub on web. Tests inject fakes.
abstract interface class HealthApi {
  /// Whether this platform can read health data at all.
  Future<bool> get isAvailable;

  /// Asks the OS for health-data access (prompts once, then returns the
  /// stored decision). True when data may be read.
  Future<bool> requestAccess();

  /// Per-day summaries for the last [days] days (1–31).
  Future<HealthSummary> summary({required int days});
}

/// Validates a `days` span argument (1–31, default 7) shared by the agent
/// tool and the JS bridge.
int healthDays(num? days) {
  if (days == null) return 7;
  final value = days.toInt();
  if (value < 1 || value > 31) {
    throw StateError('days must be between 1 and 31 (got $days)');
  }
  return value;
}
