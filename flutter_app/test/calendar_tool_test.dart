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
  int nextId = 0;
  final created = <({String title, DateTime start, DateTime end})>[];
  String? updatedId;
  DateTime? updatedStart;
  DateTime? updatedEnd;
  String? updatedTitle;
  final deletedIds = <String>[];

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

  @override
  Future<String> createEvent({
    required String title,
    required DateTime start,
    required DateTime end,
    bool allDay = false,
    String? calendar,
    String? location,
    String? notes,
  }) async {
    created.add((title: title, start: start, end: end));
    return 'fake-id-${nextId++}';
  }

  @override
  Future<void> updateEvent({
    required String id,
    String? title,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? calendar,
    String? location,
    String? notes,
  }) async {
    updatedId = id;
    updatedTitle = title;
    updatedStart = start;
    updatedEnd = end;
  }

  @override
  Future<void> deleteEvent({required String id}) async {
    deletedIds.add(id);
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
            id: 'ev-standup',
            title: 'Standup',
            start: DateTime(2026, 7, 25, 10),
            end: DateTime(2026, 7, 25, 11),
            allDay: false,
            calendar: 'Work',
            location: 'Office',
            notes: null,
          ),
          (
            id: 'ev-gym',
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

  group('calendarAddTool', () {
    test('creates the event and renders a confirmation', () async {
      final calendar = FakeCalendarApi();
      final tool = calendarAddTool(calendar);
      expect(tool.tier, ApprovalTier.write);

      final result = await tool.execute(
        const {
          'title': 'Dentist',
          'date': '2026-07-25',
          'startHour': 14,
          'endHour': 15,
        },
        null,
        null,
      );

      expect(calendar.created, hasLength(1));
      expect(calendar.created.single.title, 'Dentist');
      expect(calendar.created.single.start, DateTime(2026, 7, 25, 14));
      expect(calendar.created.single.end, DateTime(2026, 7, 25, 15));
      final text = _textOf(result);
      expect(text, contains('Created 14:00–15:00 Dentist'));
      expect(text, contains('id: fake-id-0'));
    });

    test('endHour defaults to one hour; all-day needs no hours', () async {
      final calendar = FakeCalendarApi();
      final tool = calendarAddTool(calendar);

      await tool.execute(
        const {'title': 'Lunch', 'date': '2026-07-25', 'startHour': 12},
        null,
        null,
      );
      expect(calendar.created.single.end, DateTime(2026, 7, 25, 13));

      final allDay = await tool.execute(
        const {'title': 'Vacation', 'date': '2026-07-25', 'allDay': true},
        null,
        null,
      );
      expect(_textOf(allDay), contains('Created all day Vacation'));
    });

    test('missing title or hours answers with an error text', () async {
      final calendar = FakeCalendarApi();
      final tool = calendarAddTool(calendar);

      final noTitle = await tool.execute(const {}, null, null);
      expect(_textOf(noTitle), contains('title is required'));

      await expectLater(
        tool.execute(const {'title': 'X', 'date': '2026-07-25'}, null, null),
        throwsA(isA<StateError>()),
      );
      expect(calendar.created, isEmpty);
    });

    test('denied access reports guidance and writes nothing', () async {
      final calendar = FakeCalendarApi(granted: false);
      final tool = calendarAddTool(calendar);

      final result = await tool.execute(
        const {'title': 'X', 'startHour': 9},
        null,
        null,
      );

      expect(_textOf(result), contains('denied'));
      expect(calendar.created, isEmpty);
    });
  });

  group('calendarUpdateTool', () {
    final events = [
      (
        id: 'ev-standup',
        title: 'Standup',
        start: DateTime(2026, 7, 25, 10),
        end: DateTime(2026, 7, 25, 11),
        allDay: false,
        calendar: 'Work',
        location: null,
        notes: null,
      ),
      (
        id: 'ev-gym',
        title: 'Gym',
        start: DateTime(2026, 7, 25, 18, 30),
        end: DateTime(2026, 7, 25, 19, 30),
        allDay: false,
        calendar: null,
        location: null,
        notes: null,
      ),
    ];

    test('matches by title and applies only the given fields', () async {
      final calendar = FakeCalendarApi(events: events);
      final tool = calendarUpdateTool(calendar);
      expect(tool.tier, ApprovalTier.write);

      final result = await tool.execute(
        const {
          'date': '2026-07-25',
          'match': 'gym',
          'title': 'Gym (evening)',
          'startHour': 19,
        },
        null,
        null,
      );

      expect(calendar.updatedId, 'ev-gym');
      expect(calendar.updatedTitle, 'Gym (evening)');
      expect(calendar.updatedStart, DateTime(2026, 7, 25, 19));
      expect(calendar.updatedEnd, DateTime(2026, 7, 25, 20));
      expect(_textOf(result), contains('Updated 19:00–20:00 Gym (evening)'));
    });

    test('matches by 1-based index and keeps untouched fields', () async {
      final calendar = FakeCalendarApi(events: events);
      final tool = calendarUpdateTool(calendar);

      await tool.execute(
        const {'date': '2026-07-25', 'match': '1', 'location': 'Room 4'},
        null,
        null,
      );

      expect(calendar.updatedId, 'ev-standup');
      // No hour arguments → the slot stays as it was.
      expect(calendar.updatedStart, DateTime(2026, 7, 25, 10));
      expect(calendar.updatedEnd, DateTime(2026, 7, 25, 11));
    });

    test('unknown match errors and lists the day', () async {
      final calendar = FakeCalendarApi(events: events);
      final tool = calendarUpdateTool(calendar);

      final result = await tool.execute(
        const {'date': '2026-07-25', 'match': 'brunch'},
        null,
        null,
      );

      final text = _textOf(result);
      expect(text, contains('No event matching "brunch"'));
      expect(text, contains('1. 10:00–11:00 Standup'));
      expect(text, contains('2. 18:30–19:30 Gym'));
      expect(calendar.updatedId, isNull);
    });
  });

  group('calendarDeleteTool', () {
    test('deletes the matched event and confirms', () async {
      final calendar = FakeCalendarApi(
        events: [
          (
            id: 'ev-standup',
            title: 'Standup',
            start: DateTime(2026, 7, 25, 10),
            end: DateTime(2026, 7, 25, 11),
            allDay: false,
            calendar: null,
            location: null,
            notes: null,
          ),
        ],
      );
      final tool = calendarDeleteTool(calendar);
      expect(tool.tier, ApprovalTier.write);

      final result = await tool.execute(
        const {'date': '2026-07-25', 'match': '1'},
        null,
        null,
      );

      expect(calendar.deletedIds, ['ev-standup']);
      expect(_textOf(result), contains('Deleted 10:00–11:00 Standup'));
    });

    test('unknown title errors and lists the day', () async {
      final calendar = FakeCalendarApi(
        events: [
          (
            id: 'ev-standup',
            title: 'Standup',
            start: DateTime(2026, 7, 25, 10),
            end: DateTime(2026, 7, 25, 11),
            allDay: false,
            calendar: null,
            location: null,
            notes: null,
          ),
        ],
      );
      final tool = calendarDeleteTool(calendar);

      final result = await tool.execute(
        const {'date': '2026-07-25', 'match': 'dentist'},
        null,
        null,
      );

      final text = _textOf(result);
      expect(text, contains('No event matching "dentist"'));
      expect(text, contains('1. 10:00–11:00 Standup'));
      expect(calendar.deletedIds, isEmpty);
    });

    test('index out of range errors instead of deleting', () async {
      final calendar = FakeCalendarApi(
        events: [
          (
            id: 'ev-standup',
            title: 'Standup',
            start: DateTime(2026, 7, 25, 10),
            end: DateTime(2026, 7, 25, 11),
            allDay: false,
            calendar: null,
            location: null,
            notes: null,
          ),
        ],
      );
      final tool = calendarDeleteTool(calendar);

      final result = await tool.execute(
        const {'date': '2026-07-25', 'match': '5'},
        null,
        null,
      );

      expect(_textOf(result), contains('No event matching "5"'));
      expect(calendar.deletedIds, isEmpty);
    });
  });
}
