// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/health_service.dart';

/// Name of the agent tool that reads the user's health data.
const healthSummaryToolName = 'health_summary';

/// The shared availability gate: `null` when health data may be read,
/// otherwise the user-facing explanation (unsupported platform, or access
/// denied with where to enable it). Requests OS access on the first call.
Future<String?> _unavailable(HealthApi health) async {
  if (!await health.isAvailable) {
    return 'Health data is not supported on this platform (HealthKit is '
        'available on iOS only).';
  }
  // The OS shows its access prompt at most once; later calls return the
  // stored decision without prompting again.
  if (!await health.requestAccess()) {
    return 'Health access was denied. The user can enable it in the Health '
        'app → profile picture → Apps → Fa (iOS), then ask again.';
  }
  return null;
}

/// Creates the `health_summary` tool bound to [health].
///
/// Read-only: the tool summarizes per-day steps, resting heart rate, and
/// sleep and never writes health data. When the OS has not granted access
/// yet the first call requests it (the platform prompt appears once); a
/// denial is reported with where to enable it. The description/result texts
/// are LLM-facing and stay literal English (not UI copy).
AgentTool healthSummaryTool(HealthApi health) {
  return AgentTool(
    name: healthSummaryToolName,
    label: 'health_summary',
    // Reading health data mutates nothing.
    tier: ApprovalTier.read,
    description:
        "Read the user's health data (read-only, iOS HealthKit). Use for "
        'questions like "how many steps did I walk this week?" or "how did '
        'I sleep?". Returns per-day step counts, resting heart rate, and '
        'sleep hours for a span of days.',
    parameters: const {
      'type': 'object',
      'properties': {
        'days': {
          'type': 'integer',
          'description': 'How many days back to summarize, 1-31 (default: 7)',
        },
      },
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final unavailable = await _unavailable(health);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final days = healthDays(arguments['days'] as num?);
      final summary = await health.summary(days: days);
      return ToolExecutionResult.text(_render(summary, days));
    },
  );
}

String _render(HealthSummary summary, int days) {
  final byDate = <String, Map<String, double>>{};
  void merge(List<HealthSample> samples, String key) {
    for (final sample in samples) {
      byDate.putIfAbsent(sample.date, () => {})[key] = sample.value;
    }
  }

  merge(summary.steps, 'steps');
  merge(summary.restingHeartRate, 'hr');
  merge(summary.sleepHours, 'sleep');
  final span = days == 1 ? 'the last day' : 'the last $days days';
  if (byDate.isEmpty) return 'No health data for $span.';
  final dates = byDate.keys.toList()..sort();
  final lines = [
    'Health summary for $span (most recent first):',
    for (final date in dates.reversed) '- $date: ${_renderDay(byDate[date]!)}',
  ];
  return lines.join('\n');
}

String _renderDay(Map<String, double> day) {
  final parts = <String>[
    if (day['steps'] case final steps?) '${_grouped(steps.round())} steps',
    if (day['hr'] case final hr?) 'resting HR ${hr.round()} bpm',
    if (day['sleep'] case final sleep?) 'sleep ${sleep.toStringAsFixed(1)} h',
  ];
  return parts.isEmpty ? 'no data' : parts.join(', ');
}

/// [value] with thousands separators (8432 → "8,432").
String _grouped(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
