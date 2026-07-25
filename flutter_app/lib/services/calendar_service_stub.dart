// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/calendar_service.dart';

/// Whether the current platform has a native calendar backend (macOS/iOS).
/// Always false here — this stub is selected where `dart:io` is unavailable
/// (web), so callers degrade to a clean "not supported" note.
bool get calendarPlatformSupported => false;

/// Creates the platform [CalendarApi]. On web there is no system calendar,
/// so the service reports itself unavailable and every call is a no-op.
CalendarApi createCalendarService() => const _UnavailableCalendarApi();

final class _UnavailableCalendarApi implements CalendarApi {
  const _UnavailableCalendarApi();

  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<bool> requestAccess() async => false;

  @override
  Future<List<CalendarEvent>> events({
    required DateTime start,
    required DateTime end,
  }) async => const [];

  @override
  Future<String> createEvent({
    required String title,
    required DateTime start,
    required DateTime end,
    bool allDay = false,
    String? calendar,
    String? location,
    String? notes,
  }) => throw StateError(
    'The system calendar is not supported on this platform.',
  );

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
  }) => throw StateError(
    'The system calendar is not supported on this platform.',
  );

  @override
  Future<void> deleteEvent({required String id}) => throw StateError(
    'The system calendar is not supported on this platform.',
  );
}
