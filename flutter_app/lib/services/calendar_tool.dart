// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/calendar_service.dart';

/// Name of the agent tool that reads the user's system calendar.
const calendarEventsToolName = 'calendar_events';

/// Creates the `calendar_events` tool bound to [calendar].
///
/// Read-only: the tool lists events for one local day (or a short span) and
/// never writes to the calendar. When the OS has not granted access yet the
/// first call requests it (the platform prompt appears once); a denial is
/// reported with where to enable it. The description/result texts are
/// LLM-facing and stay literal English (not UI copy).
AgentTool calendarEventsTool(CalendarApi calendar) {
  return AgentTool(
    name: calendarEventsToolName,
    label: 'calendar_events',
    // Reading calendar events mutates nothing.
    tier: ApprovalTier.read,
    description:
        "Read the user's system calendar (read-only). Use for questions "
        'like "what do I have today?" or "any meetings this week?". Returns '
        'a text list of events for one day or a short span of days.',
    parameters: const {
      'type': 'object',
      'properties': {
        'date': {
          'type': 'string',
          'description':
              'First day to list, YYYY-MM-DD (default: today, local time)',
        },
        'days': {
          'type': 'integer',
          'description': 'How many days to list, 1-31 (default: 1)',
        },
      },
    },
    execute: (arguments, cancelToken, onUpdate) async {
      if (!await calendar.isAvailable) {
        return ToolExecutionResult.text(
          'The system calendar is not supported on this platform.',
        );
      }
      final range = calendarRange(
        date: arguments['date']?.toString(),
        days: (arguments['days'] as num?)?.toInt(),
      );
      // The OS shows its access prompt at most once; later calls return the
      // stored decision without prompting again.
      if (!await calendar.requestAccess()) {
        return ToolExecutionResult.text(
          'Calendar access was denied. The user can enable it in System '
          'Settings → Privacy & Security → Calendars (macOS) or Settings → '
          'Privacy & Security → Calendars (iOS), then ask again.',
        );
      }
      final events = await calendar.events(start: range.start, end: range.end);
      return ToolExecutionResult.text(_render(events, range));
    },
  );
}

String _render(
  List<CalendarEvent> events,
  ({DateTime start, DateTime end}) range,
) {
  final sorted = [...events]..sort((a, b) => a.start.compareTo(b.start));
  final days = range.end.difference(range.start).inDays;
  final span = days == 1
      ? _dateLabel(range.start)
      : '${_dateLabel(range.start)} to ${_dateLabel(range.end.subtract(const Duration(days: 1)))}';
  if (sorted.isEmpty) return 'No events on $span.';
  final lines = [
    'Events for $span:',
    for (final event in sorted) '- ${_renderEvent(event)}',
  ];
  return lines.join('\n');
}

String _renderEvent(CalendarEvent event) {
  final when = event.allDay
      ? 'all day'
      : '${_timeLabel(event.start)}–${_timeLabel(event.end)}';
  final buffer = StringBuffer('$when ${event.title}');
  final calendar = event.calendar;
  if (calendar != null && calendar.isNotEmpty) buffer.write(' ($calendar)');
  final location = event.location;
  if (location != null && location.isNotEmpty) buffer.write(' @ $location');
  final notes = event.notes;
  if (notes != null && notes.trim().isNotEmpty) {
    var firstLine = notes.trim().split('\n').first;
    if (firstLine.length > 120) firstLine = '${firstLine.substring(0, 120)}…';
    buffer.write(' — $firstLine');
  }
  return buffer.toString();
}

String _dateLabel(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String _timeLabel(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';
