// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/calendar_service.dart';
import 'package:fa/services/calendar_tool.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Configurable fake [CalendarApi] — the host-side tests never touch the
/// real method channel.
final class FakeCalendarApi implements CalendarApi {
  FakeCalendarApi({
    this.available = true,
    this.granted = true,
    List<CalendarEvent>? events,
  }) : eventsToReturn = events ?? const [];

  bool available;
  bool granted;
  List<CalendarEvent> eventsToReturn;
  int requestAccessCalls = 0;
  DateTime? lastStart;
  DateTime? lastEnd;

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<bool> requestAccess() async {
    requestAccessCalls++;
    return granted;
  }

  @override
  Future<List<CalendarEvent>> events({
    required DateTime start,
    required DateTime end,
  }) async {
    lastStart = start;
    lastEnd = end;
    return eventsToReturn;
  }
}

String _textOf(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join();

void main() {
  group('calendarEventsTool', () {
    test('defaults to today and renders a readable list', () async {
      final calendar = FakeCalendarApi(
        events: [
          (
            title: 'Standup',
            start: DateTime(2026, 7, 25, 10),
            end: DateTime(2026, 7, 25, 11),
            allDay: false,
            calendar: 'Work',
            location: 'Office',
            notes: null,
          ),
          (
            title: 'Gym',
            start: DateTime(2026, 7, 25, 18, 30),
            end: DateTime(2026, 7, 25, 19, 30),
            allDay: false,
            calendar: null,
            location: null,
            notes: 'Bring towel',
          ),
        ],
      );
      final tool = calendarEventsTool(calendar);

      final result = await tool.execute(const {}, null, null);

      // Today, local midnight → next midnight.
      final now = DateTime.now();
      expect(calendar.lastStart, DateTime(now.year, now.month, now.day));
      expect(
        calendar.lastEnd,
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1)),
      );
      final text = _textOf(result);
      expect(text, contains('- 10:00–11:00 Standup (Work) @ Office'));
      expect(text, contains('- 18:30–19:30 Gym — Bring towel'));
    });

    test('date + days select the requested range', () async {
      final calendar = FakeCalendarApi();
      final tool = calendarEventsTool(calendar);

      await tool.execute(const {'date': '2026-07-25', 'days': 3}, null, null);

      expect(calendar.lastStart, DateTime(2026, 7, 25));
      expect(calendar.lastEnd, DateTime(2026, 7, 28));
    });

    test('empty day answers with a "no events" text', () async {
      final calendar = FakeCalendarApi();
      final tool = calendarEventsTool(calendar);

      final result = await tool.execute(
        const {'date': '2026-07-25'},
        null,
        null,
      );

      expect(_textOf(result), contains('No events on 2026-07-25'));
    });

    test('denied access requests once, then reports guidance', () async {
      final calendar = FakeCalendarApi(granted: false);
      final tool = calendarEventsTool(calendar);

      final result = await tool.execute(const {}, null, null);

      expect(calendar.requestAccessCalls, 1);
      final text = _textOf(result);
      expect(text, contains('denied'));
      expect(text, contains('Privacy & Security → Calendars'));
    });

    test('unsupported platform answers with a clean note', () async {
      final calendar = FakeCalendarApi(available: false);
      final tool = calendarEventsTool(calendar);

      final result = await tool.execute(const {}, null, null);

      expect(_textOf(result), contains('not supported on this platform'));
      expect(calendar.requestAccessCalls, 0);
    });

    test('invalid date and out-of-range days fail cleanly', () async {
      final tool = calendarEventsTool(FakeCalendarApi());
      await expectLater(
        tool.execute(const {'date': 'next friday'}, null, null),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        tool.execute(const {'days': 99}, null, null),
        throwsA(isA<StateError>()),
      );
    });
  });
}
