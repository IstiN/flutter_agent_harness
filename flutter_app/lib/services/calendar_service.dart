// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

export 'package:fa/services/calendar_service_stub.dart'
    if (dart.library.io) 'package:fa/services/calendar_service_io.dart';

/// One system-calendar event. [id] is the platform event identifier —
/// stable enough to update/delete the event later in the same session.
typedef CalendarEvent = ({
  String id,
  String title,
  DateTime start,
  DateTime end,
  bool allDay,
  String? calendar,
  String? location,
  String? notes,
});

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

  /// Creates an event and returns its new platform id. [calendar] names a
  /// target calendar; unknown/absent names fall back to the default one.
  Future<String> createEvent({
    required String title,
    required DateTime start,
    required DateTime end,
    bool allDay = false,
    String? calendar,
    String? location,
    String? notes,
  });

  /// Updates the event with [id]; only the non-null fields are applied.
  Future<void> updateEvent({
    required String id,
    String? title,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? calendar,
    String? location,
    String? notes,
  });

  /// Deletes the event with [id].
  Future<void> deleteEvent({required String id});
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
