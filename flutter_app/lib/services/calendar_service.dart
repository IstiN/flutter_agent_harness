// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

export 'package:fa/services/calendar_service_stub.dart'
    if (dart.library.io) 'package:fa/services/calendar_service_io.dart';

/// One system-calendar event. [id] is the platform event identifier —
/// stable enough to update/delete the event later in the same session.
/// [alarms] are minutes BEFORE the start (e.g. `[10, 60]`); [recurrence]
/// summarizes the first recurrence rule when the event repeats.
typedef CalendarEvent = ({
  String id,
  String title,
  DateTime start,
  DateTime end,
  bool allDay,
  String? calendar,
  String? location,
  String? notes,
  String? url,
  List<int>? alarms,
  CalendarRecurrence? recurrence,
});

/// A recurrence rule spec (maps to `EKRecurrenceRule`): [frequency] is
/// `daily`/`weekly`/`monthly`/`yearly`, [interval] ≥ 1 (default 1),
/// [daysOfWeek] (`MO`..`SU`) applies to weekly rules only (default: the
/// start date's weekday, decided natively), [daysOfMonth] (1–31) to monthly
/// rules only, and at most one of [until] / [count] bounds the series.
typedef CalendarRecurrence = ({
  String frequency,
  int interval,
  List<String>? daysOfWeek,
  List<int>? daysOfMonth,
  DateTime? until,
  int? count,
});

/// One event calendar as listed by [CalendarApi.calendars].
typedef CalendarInfo = ({String title, String source, bool writable});

/// Which occurrences a recurring-event write applies to (maps to `EKSpan`).
enum CalendarSpan {
  /// Only the matched occurrence.
  thisEvent,

  /// The matched occurrence and all future ones.
  future,
}

/// Access to the user's system calendar (EventKit on macOS/iOS).
///
/// Use [createCalendarService] (conditionally imported above) to obtain the
/// platform implementation: the `fah/calendar` method channel on IO
/// platforms, a never-available stub on web. Tests inject fakes.
abstract interface class CalendarApi {
  /// Whether this platform can read the system calendar at all.
  Future<bool> get isAvailable;

  /// Asks the OS for calendar access (prompts once, then returns the stored
  /// decision). True when events may be read.
  Future<bool> requestAccess();

  /// Events overlapping [start, end); empty when access is denied.
  Future<List<CalendarEvent>> events({
    required DateTime start,
    required DateTime end,
  });

  /// The event calendars events may be listed from / written to.
  Future<List<CalendarInfo>> calendars();

  /// Creates an event and returns its new platform id. [calendar] names a
  /// target calendar; unknown/absent names fall back to the default one.
  /// [alarms] are minutes before the start; [recurrence] repeats the event.
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
  });

  /// Updates the event with [id]; only the non-null fields are applied. A
  /// non-null [alarms] REPLACES the alarms (empty clears them);
  /// [removeRecurrence] drops the recurrence rule. [span] scopes the change
  /// for recurring events.
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
  });

  /// Deletes the event with [id]; [span] scopes it for recurring events.
  Future<void> deleteEvent({
    required String id,
    CalendarSpan span = CalendarSpan.thisEvent,
  });
}

/// Resolves a `date` (YYYY-MM-DD, default today) plus a `days` span
/// (1–31, default 1) into the local-day range [start, end) the calendar
/// tool and the JS bridge both query.
({DateTime start, DateTime end}) calendarRange({String? date, int? days}) {
  final trimmed = date?.trim() ?? '';
  final parsed = trimmed.isEmpty ? DateTime.now() : DateTime.tryParse(trimmed);
  if (parsed == null) {
    throw StateError('invalid date "$date" — expected YYYY-MM-DD');
  }
  final span = days ?? 1;
  if (span < 1 || span > 31) {
    throw StateError('days must be between 1 and 31 (got $span)');
  }
  final start = DateTime(parsed.year, parsed.month, parsed.day);
  return (start: start, end: start.add(Duration(days: span)));
}

/// Resolves a `date` day plus hour-of-day arguments into the concrete
/// local [start, end) slot the calendar write paths (agent tools, JS
/// bridge) both use. All-day events span the whole day; otherwise
/// [startHour] is required and [endHour] defaults to one hour later.
({DateTime start, DateTime end, bool allDay}) calendarSlot({
  String? date,
  num? startHour,
  num? endHour,
  bool allDay = false,
}) {
  final range = calendarRange(date: date);
  if (allDay) return (start: range.start, end: range.end, allDay: true);
  if (startHour == null) {
    throw StateError('startHour is required unless allDay is true');
  }
  final begin = startHour.toDouble();
  final finish = (endHour ?? startHour + 1).toDouble();
  if (begin < 0 || begin >= 24 || finish <= begin || finish > 24) {
    throw StateError(
      'invalid hours: need 0 <= startHour < endHour <= 24 '
      '(got $begin–$finish)',
    );
  }
  DateTime at(double hour) =>
      range.start.add(Duration(milliseconds: (hour * 3600000).round()));
  return (start: at(begin), end: at(finish), allDay: false);
}

/// Formats [date] as `YYYY-MM-DD` (the label the calendar surfaces share).
String calendarDayLabel(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// The weekday codes a weekly recurrence accepts, in Monday-first order.
const calendarWeekdayCodes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

/// Result of [parseCalendarRecurrence]: the validated [rule], or [remove]
/// when the caller asked to drop an existing rule (update convention:
/// `recurrence: 'none'` or an empty object `{}`).
typedef CalendarRecurrenceArg = ({CalendarRecurrence? rule, bool remove});

/// Parses the `recurrence` argument of the calendar write tools / JS bridge.
/// Absent (`null`) means "leave as is". Throws a [StateError] with an
/// actionable message on any invalid combination.
CalendarRecurrenceArg parseCalendarRecurrence(Object? value) {
  if (value == null) return (rule: null, remove: false);
  if (value is String) {
    if (value.trim().toLowerCase() == 'none') {
      return (rule: null, remove: true);
    }
    throw StateError(
      'invalid recurrence "$value" — pass an object like '
      '{frequency: "weekly", daysOfWeek: ["MO","WE"]}, or "none" to remove '
      'the recurrence',
    );
  }
  if (value is! Map) {
    throw StateError(
      'recurrence must be an object like {frequency: "daily"} '
      '(got ${value.runtimeType})',
    );
  }
  if (value.isEmpty) return (rule: null, remove: true);
  const knownKeys = {
    'frequency',
    'interval',
    'daysOfWeek',
    'daysOfMonth',
    'until',
    'count',
  };
  for (final key in value.keys) {
    if (!knownKeys.contains(key)) {
      throw StateError(
        'unknown recurrence key "$key" — supported keys: '
        '${knownKeys.join(', ')}',
      );
    }
  }
  final frequency = value['frequency']?.toString().trim().toLowerCase() ?? '';
  const frequencies = {'daily', 'weekly', 'monthly', 'yearly'};
  if (!frequencies.contains(frequency)) {
    throw StateError(
      'recurrence.frequency is required and must be one of: '
      '${frequencies.join(', ')} (got "$frequency")',
    );
  }
  final intervalValue = value['interval'];
  final interval = intervalValue == null
      ? 1
      : intervalValue is num
      ? intervalValue.toInt()
      : -1;
  if (interval < 1) {
    throw StateError('recurrence.interval must be an integer >= 1');
  }
  List<String>? daysOfWeek;
  final daysOfWeekValue = value['daysOfWeek'];
  if (daysOfWeekValue != null) {
    if (frequency != 'weekly') {
      throw StateError(
        'recurrence.daysOfWeek only applies to frequency "weekly" — '
        'drop it or change the frequency',
      );
    }
    if (daysOfWeekValue is! List) {
      throw StateError('recurrence.daysOfWeek must be a list like ["MO","WE"]');
    }
    daysOfWeek = [
      for (final day in daysOfWeekValue) day.toString().trim().toUpperCase(),
    ];
    for (final day in daysOfWeek) {
      if (!calendarWeekdayCodes.contains(day)) {
        throw StateError(
          'invalid recurrence.daysOfWeek entry "$day" — use two-letter '
          'codes: ${calendarWeekdayCodes.join(', ')}',
        );
      }
    }
  }
  List<int>? daysOfMonth;
  final daysOfMonthValue = value['daysOfMonth'];
  if (daysOfMonthValue != null) {
    if (frequency != 'monthly') {
      throw StateError(
        'recurrence.daysOfMonth only applies to frequency "monthly" — '
        'drop it or change the frequency',
      );
    }
    if (daysOfMonthValue is! List) {
      throw StateError('recurrence.daysOfMonth must be a list like [1, 15]');
    }
    daysOfMonth = [
      for (final day in daysOfMonthValue) day is num ? day.toInt() : -1,
    ];
    for (final day in daysOfMonth) {
      if (day < 1 || day > 31) {
        throw StateError(
          'recurrence.daysOfMonth entries must be integers 1-31 (got $day)',
        );
      }
    }
  }
  DateTime? until;
  final untilValue = value['until'];
  if (untilValue != null) {
    until = DateTime.tryParse(untilValue.toString().trim());
    if (until == null) {
      throw StateError(
        'invalid recurrence.until "$untilValue" — expected YYYY-MM-DD',
      );
    }
  }
  int? count;
  final countValue = value['count'];
  if (countValue != null) {
    count = countValue is num ? countValue.toInt() : -1;
    if (count < 1) {
      throw StateError('recurrence.count must be an integer >= 1');
    }
  }
  if (until != null && count != null) {
    throw StateError(
      'recurrence takes at most one end: "until" (a date) or "count" '
      '(a number of occurrences), not both',
    );
  }
  return (
    rule: (
      frequency: frequency,
      interval: interval,
      daysOfWeek: daysOfWeek,
      daysOfMonth: daysOfMonth,
      until: until,
      count: count,
    ),
    remove: false,
  );
}

/// Parses the `alarms` argument (minutes BEFORE the start, e.g. `[10, 60]`).
/// Absent (`null`) means "leave as is"; an empty list clears the alarms.
List<int>? parseCalendarAlarms(Object? value) {
  if (value == null) return null;
  if (value is! List) {
    throw StateError(
      'alarms must be a list of minutes before the start, e.g. [10, 60]',
    );
  }
  return [
    for (final entry in value)
      if (entry is num && entry >= 0)
        entry.toInt()
      else
        throw StateError(
          'alarms entries must be minutes >= 0 before the start '
          '(got $entry)',
        ),
  ];
}

/// Parses the `span` argument (`this` default, or `future`).
CalendarSpan parseCalendarSpan(Object? value) {
  if (value == null) return CalendarSpan.thisEvent;
  final span = value.toString().trim().toLowerCase();
  return switch (span) {
    'this' => CalendarSpan.thisEvent,
    'future' => CalendarSpan.future,
    _ => throw StateError('span must be "this" or "future" (got "$span")'),
  };
}
