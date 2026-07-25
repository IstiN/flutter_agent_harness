// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

export 'package:fa/services/calendar_service_stub.dart'
    if (dart.library.io) 'package:fa/services/calendar_service_io.dart';

/// One system-calendar event, read-only.
typedef CalendarEvent = ({
  String title,
  DateTime start,
  DateTime end,
  bool allDay,
  String? calendar,
  String? location,
  String? notes,
});

/// Read-only access to the user's system calendar (EventKit on macOS/iOS).
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
