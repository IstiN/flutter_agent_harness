// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/calendar_service.dart';

/// Name of the agent tool that reads the user's system calendar.
const calendarEventsToolName = 'calendar_events';

/// Name of the agent tool that lists the user's calendars.
const calendarCalendarsToolName = 'calendar_calendars';

/// Names of the agent tools that write to the user's system calendar.
const calendarAddToolName = 'calendar_add';
const calendarUpdateToolName = 'calendar_update';
const calendarDeleteToolName = 'calendar_delete';

/// The shared availability gate: `null` when the calendar may be used,
/// otherwise the user-facing explanation (unsupported platform, or access
/// denied with where to enable it). Requests OS access on the first call.
Future<String?> _unavailable(CalendarApi calendar) async {
  if (!await calendar.isAvailable) {
    return 'The system calendar is not supported on this platform.';
  }
  // The OS shows its access prompt at most once; later calls return the
  // stored decision without prompting again.
  if (!await calendar.requestAccess()) {
    return 'Calendar access was denied. The user can enable it in System '
        'Settings → Privacy & Security → Calendars (macOS) or Settings → '
        'Privacy & Security → Calendars (iOS), then ask again.';
  }
  return null;
}

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
      final unavailable = await _unavailable(calendar);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final range = calendarRange(
        date: arguments['date']?.toString(),
        days: (arguments['days'] as num?)?.toInt(),
      );
      final events = await calendar.events(start: range.start, end: range.end);
      return ToolExecutionResult.text(_render(events, range));
    },
  );
}

/// Creates the `calendar_calendars` tool bound to [calendar].
///
/// Read-only: lists the event calendars (title, source account, writable
/// flag) so the agent can target a specific one with the `calendar`
/// argument of the write tools.
AgentTool calendarCalendarsTool(CalendarApi calendar) {
  return AgentTool(
    name: calendarCalendarsToolName,
    label: 'calendar_calendars',
    tier: ApprovalTier.read,
    description:
        "List the user's calendars (title, source account like iCloud or "
        'Outlook, and whether each is writable). Use before calendar_add / '
        'calendar_update to pick the `calendar` argument when the user '
        'names an account.',
    parameters: const {'type': 'object', 'properties': {}},
    execute: (arguments, cancelToken, onUpdate) async {
      final unavailable = await _unavailable(calendar);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final calendars = await calendar.calendars();
      if (calendars.isEmpty) return ToolExecutionResult.text('No calendars.');
      final lines = [
        'Calendars:',
        for (final entry in calendars)
          '- ${entry.title}'
              '${entry.source.isEmpty ? '' : ' (${entry.source})'}'
              '${entry.writable ? '' : ' [read-only]'}',
      ];
      return ToolExecutionResult.text(lines.join('\n'));
    },
  );
}

/// The hour-of-day arguments the write tools share: `allDay`, or
/// `startHour` (+ optional `endHour`) on top of a `date` day.
const _slotProperties = {
  'date': {
    'type': 'string',
    'description': 'Day of the event, YYYY-MM-DD (default: today, local)',
  },
  'startHour': {
    'type': 'number',
    'description':
        'Start hour, 0-24 local (required unless allDay; may be '
        'fractional, e.g. 14.5 for 14:30)',
  },
  'endHour': {
    'type': 'number',
    'description': 'End hour, 0-24 local (default: startHour + 1)',
  },
  'allDay': {
    'type': 'boolean',
    'description': 'True for an all-day event (default: false)',
  },
  'location': {'type': 'string', 'description': 'Optional location'},
  'notes': {'type': 'string', 'description': 'Optional notes'},
  'url': {
    'type': 'string',
    'description': 'Optional URL attached to the event',
  },
  'calendar': {
    'type': 'string',
    'description':
        'Target calendar title (see calendar_calendars; unknown or absent '
        'falls back to the default calendar)',
  },
  'alarms': {
    'type': 'array',
    'items': {'type': 'integer'},
    'description':
        'Reminders as minutes BEFORE the start, e.g. [10, 60]. On update, '
        'passing alarms replaces the existing ones ([] clears them)',
  },
  'recurrence': {
    'type': 'object',
    'description':
        'Repeat rule: {frequency: "daily"|"weekly"|"monthly"|"yearly" '
        '(required), interval: int >= 1 (default 1), daysOfWeek: '
        '["MO","TU","WE","TH","FR","SA","SU"] (weekly only; default: the '
        'start date\'s weekday), daysOfMonth: [1-31] (monthly only), '
        'until: "YYYY-MM-DD", count: int >= 1} — at most one of '
        'until/count. On update, pass "none" or {} to remove the rule',
  },
};

/// The `span` argument of `calendar_update` / `calendar_delete`.
const _spanProperty = {
  'type': 'string',
  'enum': ['this', 'future'],
  'description':
      'For recurring events: "this" changes only the matched occurrence '
      '(default), "future" also the later ones',
};

/// Validates the recurrence/alarms/span arguments, answering with the
/// [StateError] text when invalid. Returns null when everything parses.
String? _validationError(Map<String, dynamic> arguments) {
  try {
    parseCalendarRecurrence(arguments['recurrence']);
    parseCalendarAlarms(arguments['alarms']);
    parseCalendarSpan(arguments['span']);
    return null;
  } on StateError catch (error) {
    return 'Error: ${error.message}';
  }
}

/// Creates the `calendar_add` tool bound to [calendar].
///
/// Tier write: creating an event mutates the user's calendar, so the
/// approval gate applies. Texts are LLM-facing and stay literal English.
AgentTool calendarAddTool(CalendarApi calendar) {
  return AgentTool(
    name: calendarAddToolName,
    label: 'calendar_add',
    tier: ApprovalTier.write,
    description:
        "Add an event to the user's system calendar. Confirm the details "
        'with the user before calling. Supports recurrence, alarms, a '
        'target calendar, and a URL. Returns the created event with its id.',
    parameters: const {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': 'Event title (required)'},
        ..._slotProperties,
      },
      'required': ['title'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final unavailable = await _unavailable(calendar);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final title = (arguments['title'] ?? '').toString().trim();
      if (title.isEmpty) {
        return ToolExecutionResult.text('Error: title is required.');
      }
      final invalid = _validationError(arguments);
      if (invalid != null) return ToolExecutionResult.text(invalid);
      final slot = _slot(arguments);
      final recurrence = parseCalendarRecurrence(arguments['recurrence']);
      final alarms = parseCalendarAlarms(arguments['alarms']);
      final id = await calendar.createEvent(
        title: title,
        start: slot.start,
        end: slot.end,
        allDay: slot.allDay,
        calendar: _text(arguments, 'calendar'),
        location: _text(arguments, 'location'),
        notes: _text(arguments, 'notes'),
        url: _text(arguments, 'url'),
        alarms: alarms,
        recurrence: recurrence.rule,
      );
      return ToolExecutionResult.text(
        'Created ${_renderEvent((id: id, title: title, start: slot.start, end: slot.end, allDay: slot.allDay, calendar: _text(arguments, 'calendar'), location: _text(arguments, 'location'), notes: _text(arguments, 'notes'), url: _text(arguments, 'url'), alarms: alarms, recurrence: recurrence.rule))} (id: $id).',
      );
    },
  );
}

/// Creates the `calendar_update` tool bound to [calendar].
///
/// The event is picked from one day's list by [calendarEventsTool]-style
/// title text or 1-based index; only the supplied fields change.
AgentTool calendarUpdateTool(CalendarApi calendar) {
  return AgentTool(
    name: calendarUpdateToolName,
    label: 'calendar_update',
    tier: ApprovalTier.write,
    description:
        "Update an event in the user's system calendar. First list the day "
        'with calendar_events, then call this with `match` set to the '
        'event title (or its 1-based index in that list) and only the '
        'fields to change. Confirm the change with the user beforehand. '
        'Pass recurrence "none" (or {}) to remove a repeat rule, alarms [] '
        'to clear reminders, and span "future" to apply the change to the '
        'matched and later occurrences.',
    parameters: {
      'type': 'object',
      'properties': {
        ..._slotProperties,
        'match': {
          'type': 'string',
          'description':
              'Which event: title text (case-insensitive) or its 1-based '
              'index in the calendar_events list for `date` (required)',
        },
        'title': {'type': 'string', 'description': 'New title'},
        'span': _spanProperty,
      },
      'required': ['match'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final unavailable = await _unavailable(calendar);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final invalid = _validationError(arguments);
      if (invalid != null) return ToolExecutionResult.text(invalid);
      final found = await _find(calendar, arguments);
      if (found.error != null) return ToolExecutionResult.text(found.error!);
      final event = found.event!;
      final hasSlot =
          arguments.containsKey('startHour') ||
          arguments.containsKey('endHour') ||
          arguments.containsKey('allDay');
      final slot = hasSlot ? _slot(arguments) : null;
      final title = _text(arguments, 'title') ?? event.title;
      final start = slot?.start ?? event.start;
      final end = slot?.end ?? event.end;
      final allDay = slot?.allDay ?? event.allDay;
      final calendarName = _text(arguments, 'calendar') ?? event.calendar;
      final location = _text(arguments, 'location') ?? event.location;
      final notes = _text(arguments, 'notes') ?? event.notes;
      final url = _text(arguments, 'url') ?? event.url;
      final recurrence = parseCalendarRecurrence(arguments['recurrence']);
      final alarms = parseCalendarAlarms(arguments['alarms']);
      final span = parseCalendarSpan(arguments['span']);
      await calendar.updateEvent(
        id: event.id,
        title: title,
        start: start,
        end: end,
        allDay: allDay,
        calendar: calendarName,
        location: location,
        notes: notes,
        url: url,
        alarms: alarms,
        recurrence: recurrence.rule,
        removeRecurrence: recurrence.remove,
        span: span,
      );
      return ToolExecutionResult.text(
        'Updated ${_renderEvent((id: event.id, title: title, start: start, end: end, allDay: allDay, calendar: calendarName, location: location, notes: notes, url: url, alarms: alarms ?? event.alarms, recurrence: recurrence.rule ?? (recurrence.remove ? null : event.recurrence)), showDate: true)}.',
      );
    },
  );
}

/// Creates the `calendar_delete` tool bound to [calendar].
///
/// List-then-confirm flow: the description steers the agent to list the
/// day first and confirm with the user; an unknown `match` answers with an
/// error that lists the day's events so the agent can recover.
AgentTool calendarDeleteTool(CalendarApi calendar) {
  return AgentTool(
    name: calendarDeleteToolName,
    label: 'calendar_delete',
    tier: ApprovalTier.write,
    description:
        "Delete an event from the user's system calendar. List-then-confirm "
        'flow: first list the day with calendar_events, confirm the exact '
        'event with the user, then call this with `match` set to the event '
        'title (or its 1-based index in that list). Deletion is permanent. '
        'For recurring events, span "future" deletes the matched and later '
        'occurrences.',
    parameters: {
      'type': 'object',
      'properties': {
        'date': _slotProperties['date']!,
        'match': {
          'type': 'string',
          'description':
              'Which event: title text (case-insensitive) or its 1-based '
              'index in the calendar_events list for `date` (required)',
        },
        'span': _spanProperty,
      },
      'required': ['match'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final unavailable = await _unavailable(calendar);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final invalid = _validationError(arguments);
      if (invalid != null) return ToolExecutionResult.text(invalid);
      final found = await _find(calendar, arguments);
      if (found.error != null) return ToolExecutionResult.text(found.error!);
      final event = found.event!;
      final span = parseCalendarSpan(arguments['span']);
      await calendar.deleteEvent(id: event.id, span: span);
      return ToolExecutionResult.text(
        'Deleted ${_renderEvent(event, showDate: true)}.',
      );
    },
  );
}

String? _text(Map<String, dynamic> arguments, String key) {
  final value = arguments[key]?.toString().trim();
  return value == null || value.isEmpty ? null : value;
}

/// Resolves the day/hour arguments into a concrete [start, end) slot.
({DateTime start, DateTime end, bool allDay}) _slot(
  Map<String, dynamic> arguments,
) => calendarSlot(
  date: arguments['date']?.toString(),
  startHour: arguments['startHour'] as num?,
  endHour: arguments['endHour'] as num?,
  allDay: arguments['allDay'] == true,
);

/// Result of [_find]: either the matched [event] or an [error] text.
typedef _FindResult = ({CalendarEvent? event, String? error});

/// Lists the `date` day and resolves the `match` argument (1-based index
/// or case-insensitive title text) against it, sorted like the read tool.
Future<_FindResult> _find(
  CalendarApi calendar,
  Map<String, dynamic> arguments,
) async {
  final matchText = (arguments['match'] ?? '').toString().trim();
  if (matchText.isEmpty) {
    return (event: null, error: 'Error: match is required.');
  }
  final range = calendarRange(date: arguments['date']?.toString());
  final events = await calendar.events(start: range.start, end: range.end);
  final sorted = [...events]..sort((a, b) => a.start.compareTo(b.start));
  final day = _dateLabel(range.start);
  String notFound() {
    if (sorted.isEmpty) {
      return 'No event matching "$matchText" on $day — the day is empty.';
    }
    final lines = [
      'No event matching "$matchText" on $day. Events that day:',
      for (var i = 0; i < sorted.length; i++)
        '${i + 1}. ${_renderEvent(sorted[i])}',
    ];
    return lines.join('\n');
  }

  final index = int.tryParse(matchText);
  if (index != null) {
    if (index < 1 || index > sorted.length) {
      return (event: null, error: notFound());
    }
    return (event: sorted[index - 1], error: null);
  }
  final needle = matchText.toLowerCase();
  final matches = sorted
      .where((event) => event.title.toLowerCase().contains(needle))
      .toList();
  if (matches.isEmpty) {
    // The event is often on ANOTHER day than the one shown (the read tool
    // defaults to today) — retry over the surrounding week before giving up.
    final wide = (
      start: range.start.subtract(const Duration(days: 7)),
      end: range.end.add(const Duration(days: 7)),
    );
    final wideEvents = await calendar.events(start: wide.start, end: wide.end);
    final wideMatches =
        (wideEvents
            .where((event) => event.title.toLowerCase().contains(needle))
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start)));
    if (wideMatches.length == 1) {
      return (event: wideMatches.single, error: null);
    }
    if (wideMatches.isNotEmpty) {
      final lines = [
        'No event matching "$matchText" on $day, but several match '
            'within ±7 days — pass the exact date:',
        for (final event in wideMatches)
          '- ${_renderEvent(event, showDate: true)}',
      ];
      return (event: null, error: lines.join('\n'));
    }
    return (event: null, error: notFound());
  }
  if (matches.length > 1) {
    final lines = [
      'Several events match "$matchText" on $day — be more specific:',
      for (final event in matches) '- ${_renderEvent(event)}',
    ];
    return (event: null, error: lines.join('\n'));
  }
  return (event: matches.single, error: null);
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
    // Multi-day spans carry the date on every row — an agent matching a
    // title must learn WHICH day the event is on, not just the time.
    for (final event in sorted) '- ${_renderEvent(event, showDate: days > 1)}',
  ];
  return lines.join('\n');
}

String _renderEvent(CalendarEvent event, {bool showDate = false}) {
  final when = event.allDay
      ? 'all day'
      : '${_timeLabel(event.start)}–${_timeLabel(event.end)}';
  final buffer = StringBuffer();
  if (showDate) buffer.write('${_dateLabel(event.start)} ');
  buffer.write('$when ${event.title}');
  final calendar = event.calendar;
  if (calendar != null && calendar.isNotEmpty) buffer.write(' ($calendar)');
  final location = event.location;
  if (location != null && location.isNotEmpty) buffer.write(' @ $location');
  final recurrence = event.recurrence;
  if (recurrence != null) buffer.write(' [${_renderRecurrence(recurrence)}]');
  final alarms = event.alarms;
  if (alarms != null && alarms.isNotEmpty) {
    final sorted = [...alarms]..sort();
    final label = sorted.map((minutes) => '${minutes}m').join(', ');
    buffer.write(
      sorted.length == 1 ? ' [alarm $label before]' : ' [alarms $label before]',
    );
  }
  final url = event.url;
  if (url != null && url.isNotEmpty) buffer.write(' [url: $url]');
  final notes = event.notes;
  if (notes != null && notes.trim().isNotEmpty) {
    var firstLine = notes.trim().split('\n').first;
    if (firstLine.length > 120) firstLine = '${firstLine.substring(0, 120)}…';
    buffer.write(' — $firstLine');
  }
  return buffer.toString();
}

/// Compact recurrence hint, e.g. `recurs weekly MO,TH until 2026-12-31`
/// or `recurs every 2 weeks ×10`.
String _renderRecurrence(CalendarRecurrence rule) {
  final buffer = StringBuffer('recurs ');
  final interval = rule.interval;
  switch (rule.frequency) {
    case 'daily':
      buffer.write(interval > 1 ? 'every $interval days' : 'daily');
    case 'weekly':
      buffer.write(interval > 1 ? 'every $interval weeks' : 'weekly');
      final days = rule.daysOfWeek;
      if (days != null && days.isNotEmpty) buffer.write(' ${days.join(',')}');
    case 'monthly':
      buffer.write(interval > 1 ? 'every $interval months' : 'monthly');
      final days = rule.daysOfMonth;
      if (days != null && days.isNotEmpty) {
        buffer.write(' on ${days.join(',')}');
      }
    case 'yearly':
      buffer.write(interval > 1 ? 'every $interval years' : 'yearly');
  }
  if (rule.until != null) buffer.write(' until ${_dateLabel(rule.until!)}');
  if (rule.count != null) buffer.write(' ×${rule.count}');
  return buffer.toString();
}

String _dateLabel(DateTime date) => calendarDayLabel(date);

String _timeLabel(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';
