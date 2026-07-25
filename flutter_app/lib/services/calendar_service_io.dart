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

/// [CalendarApi] over the `fah/calendar` method channel. Read-only: the
/// native side only ever queries EventKit, it never writes.
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
      title: textOf('title') ?? '(no title)',
      start: DateTime.fromMillisecondsSinceEpoch(msOf('startMs')),
      end: DateTime.fromMillisecondsSinceEpoch(msOf('endMs')),
      allDay: map['allDay'] == true,
      calendar: textOf('calendar'),
      location: textOf('location'),
      notes: textOf('notes'),
    );
  }
}
