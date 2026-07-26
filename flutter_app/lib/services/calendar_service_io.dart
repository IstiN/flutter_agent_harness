// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:flutter/services.dart';

import 'package:fa/services/calendar_service.dart';

/// Whether the current platform has a native calendar backend: EventKit is
/// wired up on macOS and iOS only (see `MainFlutterWindow.swift` /
/// `AppDelegate.swift`).
bool get calendarPlatformSupported => Platform.isMacOS || Platform.isIOS;

/// Creates the method-channel-backed [CalendarApi] (IO platforms).
CalendarApi createCalendarService() => const MethodChannelCalendarApi();

/// [CalendarApi] over the `fah/calendar` method channel.
final class MethodChannelCalendarApi implements CalendarApi {
  const MethodChannelCalendarApi();

  static const _channel = MethodChannel('fah/calendar');

  @override
  Future<bool> get isAvailable async => calendarPlatformSupported;

  @override
  Future<bool> requestAccess() async {
    if (!calendarPlatformSupported) return false;
    try {
      final granted = await _channel.invokeMethod<bool>('requestAccess');
      return granted ?? false;
    } on MissingPluginException {
      // No native handler (e.g. unit tests) — treat as denied.
      return false;
    }
  }

  @override
  Future<List<CalendarEvent>> events({
    required DateTime start,
    required DateTime end,
  }) async {
    if (!calendarPlatformSupported) return const [];
    final List<dynamic>? raw;
    try {
      raw = await _channel.invokeListMethod<dynamic>('events', {
        'startMs': start.millisecondsSinceEpoch,
        'endMs': end.millisecondsSinceEpoch,
      });
    } on MissingPluginException {
      return const [];
    }
    return [
      for (final entry in raw ?? const [])
        if (entry is Map) _parseEvent(entry),
    ];
  }

  static CalendarEvent _parseEvent(Map<dynamic, dynamic> map) {
    int msOf(String key) => (map[key] as num?)?.toInt() ?? 0;
    String? textOf(String key) {
      final value = map[key]?.toString();
      return value == null || value.isEmpty ? null : value;
    }

    return (
      id: textOf('id') ?? '',
      title: textOf('title') ?? '(no title)',
      start: DateTime.fromMillisecondsSinceEpoch(msOf('startMs')),
      end: DateTime.fromMillisecondsSinceEpoch(msOf('endMs')),
      allDay: map['allDay'] == true,
      calendar: textOf('calendar'),
      location: textOf('location'),
      notes: textOf('notes'),
      url: textOf('url'),
      alarms: (map['alarms'] as List?)
          ?.map((entry) => (entry as num).toInt())
          .toList(),
      recurrence: _parseRecurrence(map['recurrence']),
    );
  }

  static CalendarRecurrence? _parseRecurrence(Object? raw) {
    if (raw is! Map) return null;
    final frequency = raw['frequency']?.toString();
    if (frequency == null || frequency.isEmpty) return null;
    final untilMs = (raw['untilMs'] as num?)?.toInt();
    return (
      frequency: frequency,
      interval: (raw['interval'] as num?)?.toInt() ?? 1,
      daysOfWeek: (raw['daysOfWeek'] as List?)
          ?.map((entry) => entry.toString())
          .toList(),
      daysOfMonth: (raw['daysOfMonth'] as List?)
          ?.map((entry) => (entry as num).toInt())
          .toList(),
      until: untilMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(untilMs),
      count: (raw['count'] as num?)?.toInt(),
    );
  }

  static Map<String, Object?> _recurrenceMap(CalendarRecurrence rule) => {
    'frequency': rule.frequency,
    'interval': rule.interval,
    if (rule.daysOfWeek != null) 'daysOfWeek': rule.daysOfWeek,
    if (rule.daysOfMonth != null) 'daysOfMonth': rule.daysOfMonth,
    if (rule.until != null) 'untilMs': rule.until!.millisecondsSinceEpoch,
    if (rule.count != null) 'count': rule.count,
  };

  static String _spanName(CalendarSpan span) =>
      span == CalendarSpan.future ? 'future' : 'this';

  @override
  Future<List<CalendarInfo>> calendars() async {
    if (!calendarPlatformSupported) return const [];
    final List<dynamic>? raw;
    try {
      raw = await _channel.invokeListMethod<dynamic>('calendars');
    } on MissingPluginException {
      return const [];
    }
    return [
      for (final entry in raw ?? const [])
        if (entry is Map)
          (
            title: entry['title']?.toString() ?? '',
            source: entry['source']?.toString() ?? '',
            writable: entry['writable'] == true,
          ),
    ];
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
    String? url,
    List<int>? alarms,
    CalendarRecurrence? recurrence,
  }) async {
    _ensureSupported();
    try {
      final id = await _channel.invokeMethod<String>('createEvent', {
        'title': title,
        'startMs': start.millisecondsSinceEpoch,
        'endMs': end.millisecondsSinceEpoch,
        'allDay': allDay,
        'calendar': ?calendar,
        'location': ?location,
        'notes': ?notes,
        'url': ?url,
        'alarms': ?alarms,
        if (recurrence != null) 'recurrence': _recurrenceMap(recurrence),
      });
      return id ?? '';
    } on MissingPluginException {
      throw _unsupported();
    }
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
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('updateEvent', {
        'id': id,
        'title': ?title,
        if (start != null) 'startMs': start.millisecondsSinceEpoch,
        if (end != null) 'endMs': end.millisecondsSinceEpoch,
        'allDay': ?allDay,
        'calendar': ?calendar,
        'location': ?location,
        'notes': ?notes,
        'url': ?url,
        'alarms': ?alarms,
        if (recurrence != null) 'recurrence': _recurrenceMap(recurrence),
        if (removeRecurrence) 'removeRecurrence': true,
        'span': _spanName(span),
      });
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  @override
  Future<void> deleteEvent({
    required String id,
    CalendarSpan span = CalendarSpan.thisEvent,
  }) async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('deleteEvent', {
        'id': id,
        'span': _spanName(span),
      });
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  static void _ensureSupported() {
    if (!calendarPlatformSupported) throw _unsupported();
  }

  static StateError _unsupported() =>
      StateError('The system calendar is not supported on this platform.');
}
