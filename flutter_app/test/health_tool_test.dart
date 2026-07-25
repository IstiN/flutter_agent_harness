// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/health_service.dart';
import 'package:fa/services/health_tool.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Configurable fake [HealthApi] — the host-side tests never touch the
/// real method channel.
final class FakeHealthApi implements HealthApi {
  FakeHealthApi({
    this.available = true,
    this.granted = true,
    HealthSummary? summary,
  }) : summaryToReturn =
           summary ??
           (steps: const [], restingHeartRate: const [], sleepHours: const []);

  bool available;
  bool granted;
  HealthSummary summaryToReturn;
  int requestAccessCalls = 0;
  int? lastDays;

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<bool> requestAccess() async {
    requestAccessCalls++;
    return granted;
  }

  @override
  Future<HealthSummary> summary({required int days}) async {
    lastDays = days;
    return summaryToReturn;
  }
}

String _textOf(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join();

void main() {
  group('healthSummaryTool', () {
    test('is a read-tier tool', () {
      expect(healthSummaryTool(FakeHealthApi()).tier, ApprovalTier.read);
      expect(healthSummaryTool(FakeHealthApi()).name, healthSummaryToolName);
    });

    test('renders a readable per-day summary, most recent first', () async {
      final health = FakeHealthApi(
        summary: (
          steps: const [
            (date: '2026-07-24', value: 5210),
            (date: '2026-07-25', value: 8432),
          ],
          restingHeartRate: const [(date: '2026-07-25', value: 62)],
          sleepHours: const [
            (date: '2026-07-24', value: 6.5),
            (date: '2026-07-25', value: 7.2),
          ],
        ),
      );
      final tool = healthSummaryTool(health);

      final result = await tool.execute(const {'days': 7}, null, null);

      expect(health.lastDays, 7);
      final text = _textOf(result);
      expect(text, contains('Health summary for the last 7 days'));
      expect(
        text,
        contains(
          '- 2026-07-25: 8,432 steps, resting HR 62 bpm, '
          'sleep 7.2 h',
        ),
      );
      expect(text, contains('- 2026-07-24: 5,210 steps, sleep 6.5 h'));
      // Most recent day comes first.
      expect(text.indexOf('2026-07-25'), lessThan(text.indexOf('2026-07-24')));
    });

    test('defaults to 7 days', () async {
      final health = FakeHealthApi();
      final tool = healthSummaryTool(health);

      await tool.execute(const {}, null, null);

      expect(health.lastDays, 7);
    });

    test('empty span answers with a "no data" text', () async {
      final health = FakeHealthApi();
      final tool = healthSummaryTool(health);

      final result = await tool.execute(const {'days': 3}, null, null);

      expect(_textOf(result), contains('No health data for the last 3 days'));
    });

    test('denied access requests once, then reports guidance', () async {
      final health = FakeHealthApi(granted: false);
      final tool = healthSummaryTool(health);

      final result = await tool.execute(const {}, null, null);

      expect(health.requestAccessCalls, 1);
      final text = _textOf(result);
      expect(text, contains('denied'));
      expect(text, contains('Health app'));
    });

    test('unsupported platform answers with a clean note', () async {
      final health = FakeHealthApi(available: false);
      final tool = healthSummaryTool(health);

      final result = await tool.execute(const {}, null, null);

      expect(_textOf(result), contains('not supported on this platform'));
      expect(health.requestAccessCalls, 0);
    });

    test('out-of-range days fail cleanly', () async {
      final tool = healthSummaryTool(FakeHealthApi());
      await expectLater(
        tool.execute(const {'days': 99}, null, null),
        throwsA(isA<StateError>()),
      );
    });
  });
}
