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
    this.calendarsToReturn = const [],
  }) : eventsToReturn = events ?? const [];

  bool available;
  bool granted;
  List<CalendarEvent> eventsToReturn;
  List<CalendarInfo> calendarsToReturn;
  int requestAccessCalls = 0;
  DateTime? lastStart;
  DateTime? lastEnd;
  int nextId = 0;
  final created = <({String title, DateTime start, DateTime end})>[];
  String? createdCalendar;
  String? createdUrl;
  List<int>? createdAlarms;
  CalendarRecurrence? createdRecurrence;
  String? updatedId;
  DateTime? updatedStart;
  DateTime? updatedEnd;
  String? updatedTitle;
  String? updatedCalendar;
  String? updatedUrl;
  List<int>? updatedAlarms;
  CalendarRecurrence? updatedRecurrence;
  bool updatedRemoveRecurrence = false;
  CalendarSpan updatedSpan = CalendarSpan.thisEvent;
  final deletedIds = <String>[];
  final deletedSpans = <CalendarSpan>[];

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
    // Range-filtered like the real EventKit predicate.
    return eventsToReturn
        .where((e) => e.end.isAfter(start) && e.start.isBefore(end))
        .toList();
  }

  @override
  Future<List<CalendarInfo>> calendars() async => calendarsToReturn;

  @override
  Future<String> createEvent({
    required String title,
    required DateTime start,
    required DateTime end,
    bool allDay = false,
    String? calendar,
    String? location,
    String? notes,
    String? url,
    List<int>? alarms,
    CalendarRecurrence? recurrence,
  }) async {
    created.add((title: title, start: start, end: end));
    createdCalendar = calendar;
    createdUrl = url;
    createdAlarms = alarms;
    createdRecurrence = recurrence;
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
    String? url,
    List<int>? alarms,
    CalendarRecurrence? recurrence,
    bool removeRecurrence = false,
    CalendarSpan span = CalendarSpan.thisEvent,
  }) async {
    updatedId = id;
    updatedTitle = title;
    updatedStart = start;
    updatedEnd = end;
    updatedCalendar = calendar;
    updatedUrl = url;
    updatedAlarms = alarms;
    updatedRecurrence = recurrence;
    updatedRemoveRecurrence = removeRecurrence;
    updatedSpan = span;
  }

  @override
  Future<void> deleteEvent({
    required String id,
    CalendarSpan span = CalendarSpan.thisEvent,
  }) async {
    deletedIds.add(id);
    deletedSpans.add(span);
  }
}

CalendarEvent _event({
  required String id,
  required String title,
  required DateTime start,
  required DateTime end,
  bool allDay = false,
  String? calendar,
  String? location,
  String? notes,
  String? url,
  List<int>? alarms,
  CalendarRecurrence? recurrence,
}) => (
  id: id,
  title: title,
  start: start,
  end: end,
  allDay: allDay,
  calendar: calendar,
  location: location,
  notes: notes,
  url: url,
  alarms: alarms,
  recurrence: recurrence,
);

String _textOf(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join();

void main() {
  group('calendarEventsTool', () {
    test('defaults to today and renders a readable list', () async {
      final today = DateTime.now();
      final day = DateTime(today.year, today.month, today.day);
      final calendar = FakeCalendarApi(
        events: [
          _event(
            id: 'ev-standup',
            title: 'Standup',
            start: day.add(const Duration(hours: 10)),
            end: day.add(const Duration(hours: 11)),
            calendar: 'Work',
            location: 'Office',
          ),
          _event(
            id: 'ev-gym',
            title: 'Gym',
            start: day.add(const Duration(hours: 18, minutes: 30)),
            end: day.add(const Duration(hours: 19, minutes: 30)),
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

    test('renders recurrence, alarms, and url hints when present', () async {
      final day = DateTime(2026, 7, 25);
      final calendar = FakeCalendarApi(
        events: [
          _event(
            id: 'ev-sync',
            title: 'Sync',
            start: day.add(const Duration(hours: 9)),
            end: day.add(const Duration(hours: 9, minutes: 30)),
            recurrence: (
              frequency: 'weekly',
              interval: 1,
              daysOfWeek: const ['MO', 'TH'],
              daysOfMonth: null,
              until: DateTime(2026, 12, 31),
              count: null,
            ),
            alarms: const [10],
            url: 'https://meet.example.com/sync',
          ),
          _event(
            id: 'ev-report',
            title: 'Report',
            start: day.add(const Duration(hours: 17)),
            end: day.add(const Duration(hours: 18)),
            recurrence: (
              frequency: 'daily',
              interval: 1,
              daysOfWeek: null,
              daysOfMonth: null,
              until: null,
              count: 10,
            ),
            alarms: const [60, 10],
          ),
        ],
      );
      final tool = calendarEventsTool(calendar);

      final result = await tool.execute(
        const {'date': '2026-07-25'},
        null,
        null,
      );

      final text = _textOf(result);
      expect(
        text,
        contains(
          '- 09:00–09:30 Sync [recurs weekly MO,TH until 2026-12-31] '
          '[alarm 10m before] [url: https://meet.example.com/sync]',
        ),
      );
      expect(
        text,
        contains(
          '- 17:00–18:00 Report [recurs daily ×10] [alarms 10m, 60m before]',
        ),
      );
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

  group('calendarCalendarsTool', () {
    test('lists calendars with source and read-only flag', () async {
      final calendar = FakeCalendarApi(
        calendarsToReturn: const [
          (title: 'Work', source: 'Outlook', writable: true),
          (title: 'Home', source: 'iCloud', writable: true),
          (title: 'Holidays', source: 'Other', writable: false),
        ],
      );
      final tool = calendarCalendarsTool(calendar);
      expect(tool.tier, ApprovalTier.read);

      final result = await tool.execute(const {}, null, null);

      final text = _textOf(result);
      expect(text, contains('- Work (Outlook)'));
      expect(text, contains('- Home (iCloud)'));
      expect(text, contains('- Holidays (Other) [read-only]'));
    });

    test('empty list and denied access answer cleanly', () async {
      final empty = await calendarCalendarsTool(
        FakeCalendarApi(),
      ).execute(const {}, null, null);
      expect(_textOf(empty), contains('No calendars'));

      final denied = await calendarCalendarsTool(
        FakeCalendarApi(granted: false),
      ).execute(const {}, null, null);
      expect(_textOf(denied), contains('denied'));
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

    test('forwards recurrence, alarms, calendar, and url', () async {
      final calendar = FakeCalendarApi();
      final tool = calendarAddTool(calendar);

      final result = await tool.execute(
        const {
          'title': 'Gym',
          'date': '2026-07-27', // a Monday
          'startHour': 18,
          'calendar': 'Work',
          'url': 'https://gym.example.com',
          'alarms': [10, 60],
          'recurrence': {
            'frequency': 'weekly',
            'daysOfWeek': ['MO', 'WE'],
            'count': 12,
          },
        },
        null,
        null,
      );

      expect(calendar.createdCalendar, 'Work');
      expect(calendar.createdUrl, 'https://gym.example.com');
      expect(calendar.createdAlarms, [10, 60]);
      final rule = calendar.createdRecurrence!;
      expect(rule.frequency, 'weekly');
      expect(rule.interval, 1);
      expect(rule.daysOfWeek, ['MO', 'WE']);
      expect(rule.count, 12);
      final text = _textOf(result);
      expect(text, contains('recurs weekly MO,WE ×12'));
      expect(text, contains('alarms 10m, 60m before'));
    });

    test('recurrence until parses into a date bound', () async {
      final calendar = FakeCalendarApi();
      final tool = calendarAddTool(calendar);

      await tool.execute(
        const {
          'title': 'Standup',
          'startHour': 10,
          'recurrence': {'frequency': 'daily', 'until': '2026-12-31'},
        },
        null,
        null,
      );

      final rule = calendar.createdRecurrence!;
      expect(rule.frequency, 'daily');
      expect(rule.until, DateTime(2026, 12, 31));
      expect(rule.count, isNull);
    });

    test('invalid recurrence combos answer with actionable errors', () async {
      final calendar = FakeCalendarApi();
      final tool = calendarAddTool(calendar);

      final daysOnDaily = await tool.execute(
        const {
          'title': 'X',
          'startHour': 9,
          'recurrence': {
            'frequency': 'daily',
            'daysOfWeek': ['MO'],
          },
        },
        null,
        null,
      );
      expect(
        _textOf(daysOnDaily),
        contains('daysOfWeek only applies to frequency "weekly"'),
      );

      final bothEnds = await tool.execute(
        const {
          'title': 'X',
          'startHour': 9,
          'recurrence': {
            'frequency': 'monthly',
            'until': '2026-12-31',
            'count': 5,
          },
        },
        null,
        null,
      );
      expect(_textOf(bothEnds), contains('at most one end'));

      final noFrequency = await tool.execute(
        const {
          'title': 'X',
          'startHour': 9,
          'recurrence': {'interval': 2},
        },
        null,
        null,
      );
      expect(_textOf(noFrequency), contains('frequency is required'));

      final badWeekday = await tool.execute(
        const {
          'title': 'X',
          'startHour': 9,
          'recurrence': {
            'frequency': 'weekly',
            'daysOfWeek': ['monday'],
          },
        },
        null,
        null,
      );
      // Lowercase full names are not two-letter codes.
      expect(_textOf(badWeekday), contains('invalid recurrence.daysOfWeek'));

      final badAlarms = await tool.execute(
        const {
          'title': 'X',
          'startHour': 9,
          'alarms': [-5],
        },
        null,
        null,
      );
      expect(_textOf(badAlarms), contains('minutes >= 0'));

      expect(calendar.created, isEmpty);
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
      _event(
        id: 'ev-standup',
        title: 'Standup',
        start: DateTime(2026, 7, 25, 10),
        end: DateTime(2026, 7, 25, 11),
        calendar: 'Work',
      ),
      _event(
        id: 'ev-gym',
        title: 'Gym',
        start: DateTime(2026, 7, 25, 18, 30),
        end: DateTime(2026, 7, 25, 19, 30),
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
      expect(
        _textOf(result),
        contains('Updated 2026-07-25 19:00–20:00 Gym (evening)'),
      );
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
      expect(calendar.updatedCalendar, 'Work');
    });

    test(
      'forwards recurrence change, alarms, calendar, url, and span',
      () async {
        final calendar = FakeCalendarApi(events: events);
        final tool = calendarUpdateTool(calendar);

        await tool.execute(
          const {
            'date': '2026-07-25',
            'match': '1',
            'calendar': 'Home',
            'url': 'https://example.com/standup',
            'alarms': [15],
            'recurrence': {'frequency': 'daily', 'interval': 2},
            'span': 'future',
          },
          null,
          null,
        );

        expect(calendar.updatedId, 'ev-standup');
        expect(calendar.updatedCalendar, 'Home');
        expect(calendar.updatedUrl, 'https://example.com/standup');
        expect(calendar.updatedAlarms, [15]);
        expect(calendar.updatedRecurrence!.frequency, 'daily');
        expect(calendar.updatedRecurrence!.interval, 2);
        expect(calendar.updatedRemoveRecurrence, isFalse);
        expect(calendar.updatedSpan, CalendarSpan.future);
      },
    );

    test('recurrence "none" and {} remove the rule', () async {
      for (final removal in [
        const {'recurrence': 'none'},
        const {'recurrence': <String, Object?>{}},
      ]) {
        final calendar = FakeCalendarApi(events: events);
        final tool = calendarUpdateTool(calendar);

        await tool.execute(
          {'date': '2026-07-25', 'match': '1', ...removal},
          null,
          null,
        );

        expect(calendar.updatedRecurrence, isNull);
        expect(calendar.updatedRemoveRecurrence, isTrue);
      }
    });

    test('absent alarms leave them untouched, [] clears them', () async {
      final calendar = FakeCalendarApi(events: events);
      final tool = calendarUpdateTool(calendar);

      await tool.execute(
        const {'date': '2026-07-25', 'match': '1', 'title': 'Standup!'},
        null,
        null,
      );
      expect(calendar.updatedAlarms, isNull);

      await tool.execute(
        const {'date': '2026-07-25', 'match': '1', 'alarms': <int>[]},
        null,
        null,
      );
      expect(calendar.updatedAlarms, isEmpty);
    });

    test(
      'invalid recurrence answers with an error and writes nothing',
      () async {
        final calendar = FakeCalendarApi(events: events);
        final tool = calendarUpdateTool(calendar);

        final result = await tool.execute(
          const {
            'date': '2026-07-25',
            'match': '1',
            'recurrence': {
              'frequency': 'weekly',
              'daysOfMonth': [1],
            },
          },
          null,
          null,
        );

        expect(
          _textOf(result),
          contains('daysOfMonth only applies to frequency "monthly"'),
        );
        expect(calendar.updatedId, isNull);
      },
    );

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
          _event(
            id: 'ev-standup',
            title: 'Standup',
            start: DateTime(2026, 7, 25, 10),
            end: DateTime(2026, 7, 25, 11),
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
      expect(calendar.deletedSpans, [CalendarSpan.thisEvent]);
      expect(
        _textOf(result),
        contains('Deleted 2026-07-25 10:00–11:00 Standup'),
      );
    });

    test('span future is forwarded for recurring events', () async {
      final calendar = FakeCalendarApi(
        events: [
          _event(
            id: 'ev-gym',
            title: 'Gym',
            start: DateTime(2026, 7, 25, 18),
            end: DateTime(2026, 7, 25, 19),
            recurrence: (
              frequency: 'daily',
              interval: 1,
              daysOfWeek: null,
              daysOfMonth: null,
              until: null,
              count: null,
            ),
          ),
        ],
      );
      final tool = calendarDeleteTool(calendar);

      final result = await tool.execute(
        const {'date': '2026-07-25', 'match': 'gym', 'span': 'future'},
        null,
        null,
      );

      expect(calendar.deletedIds, ['ev-gym']);
      expect(calendar.deletedSpans, [CalendarSpan.future]);
      expect(_textOf(result), contains('recurs daily'));
    });

    test('invalid span answers with an error and deletes nothing', () async {
      final calendar = FakeCalendarApi(
        events: [
          _event(
            id: 'ev-standup',
            title: 'Standup',
            start: DateTime(2026, 7, 25, 10),
            end: DateTime(2026, 7, 25, 11),
          ),
        ],
      );
      final tool = calendarDeleteTool(calendar);

      final result = await tool.execute(
        const {'date': '2026-07-25', 'match': '1', 'span': 'all'},
        null,
        null,
      );

      expect(_textOf(result), contains('span must be "this" or "future"'));
      expect(calendar.deletedIds, isEmpty);
    });

    test('a match on another day is found within ±7 days', () async {
      final calendar = FakeCalendarApi(
        events: [
          _event(
            id: 'ev-training',
            title: 'Visit training',
            start: DateTime(2026, 7, 27, 18),
            end: DateTime(2026, 7, 27, 19),
            calendar: 'Calendar',
          ),
        ],
      );
      final tool = calendarDeleteTool(calendar);

      final result = await tool.execute(
        const {'date': '2026-07-26', 'match': 'visit training'},
        null,
        null,
      );

      expect(calendar.deletedIds, ['ev-training']);
      expect(
        _textOf(result),
        contains('Deleted 2026-07-27 18:00–19:00 Visit training'),
      );
    });

    test('several matches within ±7 days ask for the exact date', () async {
      final calendar = FakeCalendarApi(
        events: [
          _event(
            id: 'ev-a',
            title: 'Visit training',
            start: DateTime(2026, 7, 27, 18),
            end: DateTime(2026, 7, 27, 19),
          ),
          _event(
            id: 'ev-b',
            title: 'Visit training',
            start: DateTime(2026, 7, 29, 18),
            end: DateTime(2026, 7, 29, 19),
          ),
        ],
      );
      final tool = calendarDeleteTool(calendar);

      final result = await tool.execute(
        const {'date': '2026-07-26', 'match': 'visit training'},
        null,
        null,
      );

      expect(calendar.deletedIds, isEmpty);
      final text = _textOf(result);
      expect(text, contains('pass the exact date'));
      expect(text, contains('2026-07-27'));
      expect(text, contains('2026-07-29'));
    });

    test('unknown title errors and lists the day', () async {
      final calendar = FakeCalendarApi(
        events: [
          _event(
            id: 'ev-standup',
            title: 'Standup',
            start: DateTime(2026, 7, 25, 10),
            end: DateTime(2026, 7, 25, 11),
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
          _event(
            id: 'ev-standup',
            title: 'Standup',
            start: DateTime(2026, 7, 25, 10),
            end: DateTime(2026, 7, 25, 11),
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
