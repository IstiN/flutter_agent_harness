// Table tests for the calendar recurrence-argument parser
// (`parseCalendarRecurrence`) — the pure RRULE-subset validator shared by
// the calendar tools and the JS bridge. The rule fields are passed to the
// platform calendar (EventKit / CalendarContract), which owns expansion —
// these tables pin the contract the platform receives, including the
// DST-boundary fixture dates (`until` lands on local midnight, which
// exists on every spring-forward/fall-back day).
import 'package:fa/services/calendar_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('absent / remove conventions', () {
    test('null means "leave as is"', () {
      final arg = parseCalendarRecurrence(null);
      expect(arg.rule, isNull);
      expect(arg.remove, isFalse);
    });

    test('empty map removes', () {
      final arg = parseCalendarRecurrence(<String, dynamic>{});
      expect(arg.rule, isNull);
      expect(arg.remove, isTrue);
    });

    test('"none" removes, case and whitespace insensitive', () {
      for (final raw in ['none', ' NONE ', 'None']) {
        final arg = parseCalendarRecurrence(raw);
        expect(arg.rule, isNull, reason: raw);
        expect(arg.remove, isTrue, reason: raw);
      }
    });
  });

  group('rejected shapes', () {
    test('non-none string names the object shape', () {
      expect(
        () => parseCalendarRecurrence('weekly'),
        throwsStateErrorWith(
          'invalid recurrence "weekly" — pass an object like '
          '{frequency: "weekly", daysOfWeek: ["MO","WE"]}, or "none" to '
          'remove the recurrence',
        ),
      );
    });

    test('non-map non-string names the runtime type', () {
      expect(
        () => parseCalendarRecurrence(42),
        throwsStateErrorWith(
          'recurrence must be an object like {frequency: "daily"} '
          '(got int)',
        ),
      );
    });

    test('unknown key lists the supported set', () {
      expect(
        () => parseCalendarRecurrence({
          'frequency': 'daily',
          'byDay': ['MO'],
        }),
        throwsStateErrorWith(
          'unknown recurrence key "byDay" — supported keys: frequency, '
          'interval, daysOfWeek, daysOfMonth, until, count',
        ),
      );
    });
  });

  group('frequency', () {
    test('missing frequency is rejected (non-empty map, known keys)', () {
      expect(
        () => parseCalendarRecurrence({'interval': 2}),
        throwsStateErrorWith(
          'recurrence.frequency is required and must be one of: daily, '
          'weekly, monthly, yearly (got "")',
        ),
      );
    });

    for (final frequency in ['daily', 'weekly', 'monthly', 'yearly']) {
      test('"$frequency" parses (case/space tolerant)', () {
        final arg = parseCalendarRecurrence({'frequency': ' $frequency '});
        expect(arg.remove, isFalse);
        expect(arg.rule!.frequency, frequency);
        expect(arg.rule!.interval, 1);
        expect(arg.rule!.daysOfWeek, isNull);
        expect(arg.rule!.daysOfMonth, isNull);
        expect(arg.rule!.until, isNull);
        expect(arg.rule!.count, isNull);
      });
    }

    test('bad frequency message enumerates the set', () {
      expect(
        () => parseCalendarRecurrence({'frequency': 'hourly'}),
        throwsStateErrorWith(
          'recurrence.frequency is required and must be one of: daily, '
          'weekly, monthly, yearly (got "hourly")',
        ),
      );
    });
  });

  group('interval', () {
    test('defaults to 1', () {
      expect(
        parseCalendarRecurrence({'frequency': 'daily'}).rule!.interval,
        1,
      );
    });

    test('integer >= 1 accepted (num includes doubles)', () {
      expect(
        parseCalendarRecurrence({
          'frequency': 'daily',
          'interval': 2.0,
        }).rule!.interval,
        2,
      );
    });

    test('< 1 rejected', () {
      for (final raw in [0, -1]) {
        expect(
          () => parseCalendarRecurrence({
            'frequency': 'daily',
            'interval': raw,
          }),
          throwsStateErrorWith(
            'recurrence.interval must be an integer >= 1',
          ),
          reason: '$raw',
        );
      }
    });

    test('non-numeric rejected', () {
      expect(
        () => parseCalendarRecurrence({
          'frequency': 'daily',
          'interval': 'two',
        }),
        throwsStateErrorWith('recurrence.interval must be an integer >= 1'),
      );
    });
  });

  group('daysOfWeek (weekly only)', () {
    test('codes normalize to upper-case trimmed codes', () {
      expect(
        parseCalendarRecurrence({
          'frequency': 'weekly',
          'daysOfWeek': ['mo', ' we '],
        }).rule!.daysOfWeek,
        ['MO', 'WE'],
      );
    });

    test('every weekday code is accepted', () {
      expect(
        parseCalendarRecurrence({
          'frequency': 'weekly',
          'daysOfWeek': calendarWeekdayCodes,
        }).rule!.daysOfWeek,
        calendarWeekdayCodes,
      );
    });

    test('rejected outside weekly', () {
      expect(
        () => parseCalendarRecurrence({
          'frequency': 'daily',
          'daysOfWeek': ['MO'],
        }),
        throwsStateErrorWith(
          'recurrence.daysOfWeek only applies to frequency "weekly" — '
          'drop it or change the frequency',
        ),
      );
    });

    test('non-list rejected', () {
      expect(
        () => parseCalendarRecurrence({
          'frequency': 'weekly',
          'daysOfWeek': 'MO',
        }),
        throwsStateErrorWith(
          'recurrence.daysOfWeek must be a list like ["MO","WE"]',
        ),
      );
    });

    test('invalid entry names the entry', () {
      expect(
        () => parseCalendarRecurrence({
          'frequency': 'weekly',
          'daysOfWeek': ['MO', 'XX'],
        }),
        throwsStateErrorWith(
          'invalid recurrence.daysOfWeek entry "XX" — use two-letter '
          'codes: MO, TU, WE, TH, FR, SA, SU',
        ),
      );
    });
  });

  group('daysOfMonth (monthly only)', () {
    test('1..31 accepted', () {
      expect(
        parseCalendarRecurrence({
          'frequency': 'monthly',
          'daysOfMonth': [1, 15, 31],
        }).rule!.daysOfMonth,
        [1, 15, 31],
      );
    });

    test('rejected outside monthly', () {
      expect(
        () => parseCalendarRecurrence({
          'frequency': 'yearly',
          'daysOfMonth': [1],
        }),
        throwsStateErrorWith(
          'recurrence.daysOfMonth only applies to frequency "monthly" — '
          'drop it or change the frequency',
        ),
      );
    });

    test('non-list rejected', () {
      expect(
        () => parseCalendarRecurrence({
          'frequency': 'monthly',
          'daysOfMonth': 15,
        }),
        throwsStateErrorWith(
          'recurrence.daysOfMonth must be a list like [1, 15]',
        ),
      );
    });

    test('out-of-range and non-numeric entries rejected', () {
      for (final entry in [0, 32, '15']) {
        expect(
          () => parseCalendarRecurrence({
            'frequency': 'monthly',
            'daysOfMonth': [entry],
          }),
          throwsStateErrorWith(
            'recurrence.daysOfMonth entries must be integers 1-31',
          ),
          reason: '$entry',
        );
      }
    });
  });

  group('until / count end bounds', () {
    test('until parses a date to local midnight', () {
      expect(
        parseCalendarRecurrence({
          'frequency': 'daily',
          'until': ' 2026-12-31 ',
        }).rule!.until,
        DateTime(2026, 12, 31),
      );
    });

    test('invalid until is rejected', () {
      expect(
        () => parseCalendarRecurrence({
          'frequency': 'daily',
          'until': 'not-a-date',
        }),
        throwsStateErrorWith(
          'invalid recurrence.until "not-a-date" — expected YYYY-MM-DD',
        ),
      );
    });

    test('count parses an integer >= 1', () {
      expect(
        parseCalendarRecurrence({
          'frequency': 'daily',
          'count': 5,
        }).rule!.count,
        5,
      );
    });

    test('count < 1 and non-numeric rejected', () {
      expect(
        () => parseCalendarRecurrence({
          'frequency': 'daily',
          'count': 0,
        }),
        throwsStateErrorWith('recurrence.count must be an integer >= 1'),
      );
      expect(
        () => parseCalendarRecurrence({
          'frequency': 'daily',
          'count': 'five',
        }),
        throwsStateErrorWith('recurrence.count must be an integer >= 1'),
      );
    });

    test('until and count are mutually exclusive', () {
      expect(
        () => parseCalendarRecurrence({
          'frequency': 'daily',
          'until': '2026-12-31',
          'count': 5,
        }),
        throwsStateErrorWith(
          'recurrence takes at most one end: "until" (a date) or "count" '
          '(a number of occurrences), not both',
        ),
      );
    });
  });

  group('fixture calendar: DST boundary dates (local midnight exists on '
      'every transition day)', () {
    // US spring forward 2026-03-08 (02:00 → 03:00 local) and EU spring
    // forward 2026-03-29 (01:00 → 02:00 UTC): both midnights are real
    // local times, and tryParse('YYYY-MM-DD') must land on them exactly —
    // the platform RRULE walker receives a stable series start bound.
    for (final entry in const [
      (date: '2026-03-08', expected: (2026, 3, 8), label: 'US spring fwd'),
      (date: '2026-11-01', expected: (2026, 11, 1), label: 'US fall back'),
      (date: '2026-03-29', expected: (2026, 3, 29), label: 'EU spring fwd'),
      (date: '2026-10-25', expected: (2026, 10, 25), label: 'EU fall back'),
    ]) {
      test('until ${entry.label} ${entry.date}', () {
        final rule = parseCalendarRecurrence({
          'frequency': 'daily',
          'until': entry.date,
        }).rule!;
        final (y, m, d) = entry.expected;
        expect(rule.until, DateTime(y, m, d));
        expect(rule.until!.timeZoneOffset, DateTime(y, m, d).timeZoneOffset);
      });
    }
  });
}

/// A pocket matcher: the parser reports every problem as a [StateError]
/// whose message IS the user-facing contract.
Matcher throwsStateErrorWith(String message) => throwsA(
  isA<StateError>().having((e) => e.message, 'message', contains(message)),
);
