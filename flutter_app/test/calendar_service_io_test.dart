// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/calendar_service_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MethodChannelCalendarApi.parseRecurrence', () {
    test('non-map payloads decode to null', () {
      expect(MethodChannelCalendarApi.parseRecurrence(null), isNull);
      expect(MethodChannelCalendarApi.parseRecurrence('weekly'), isNull);
      expect(MethodChannelCalendarApi.parseRecurrence(42), isNull);
    });

    test('a missing or blank frequency is rejected', () {
      expect(MethodChannelCalendarApi.parseRecurrence({}), isNull);
      expect(
        MethodChannelCalendarApi.parseRecurrence({'frequency': ''}),
        isNull,
      );
    });

    test('a full rule decodes every field', () {
      final rule = MethodChannelCalendarApi.parseRecurrence({
        'frequency': 'monthly',
        'interval': 2,
        'daysOfWeek': ['MO', 'FR'],
        'daysOfMonth': [1, 15],
        'untilMs': DateTime(2026, 12, 31).millisecondsSinceEpoch,
        'count': 6,
      });
      expect(rule, isNotNull);
      expect(rule!.frequency, 'monthly');
      expect(rule.interval, 2);
      expect(rule.daysOfWeek, ['MO', 'FR']);
      expect(rule.daysOfMonth, [1, 15]);
      expect(rule.until, DateTime(2026, 12, 31));
      expect(rule.count, 6);
    });

    test('optional fields default to interval 1 and no bound', () {
      final rule = MethodChannelCalendarApi.parseRecurrence({
        'frequency': 'daily',
      });
      expect(rule!.interval, 1);
      expect(rule.daysOfWeek, isNull);
      expect(rule.daysOfMonth, isNull);
      expect(rule.until, isNull);
      expect(rule.count, isNull);
    });
  });
}
