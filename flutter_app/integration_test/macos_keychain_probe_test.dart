import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Live macOS probe for the keychain channel + calendar access request:
/// the two things that fail silently on this machine (key not persisted,
/// no Privacy prompt ever appears).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('keychain set/read/delete round-trip on macOS', (tester) async {
    const channel = MethodChannel('fah/keychain');
    final available = await channel.invokeMethod<bool>('isAvailable');
    print('[keychain] isAvailable=$available');

    final setOk = await channel.invokeMethod<bool>('set', {
      'name': 'PROBE_KEY',
      'value': 'probe-value-123',
    });
    print('[keychain] set=$setOk');

    final all =
        (await channel.invokeMethod<Map>('readAll'))?.cast<String, String>() ??
        {};
    print('[keychain] readAll keys=${all.keys.toList()}');
    print('[keychain] probe value=${all['PROBE_KEY']}');

    final delOk = await channel.invokeMethod<bool>('delete', {
      'name': 'PROBE_KEY',
    });
    print('[keychain] delete=$delOk');

    expect(setOk, isTrue, reason: 'keychain set failed');
    expect(all['PROBE_KEY'], 'probe-value-123');
  });

  testWidgets('calendar requestAccess actually asks (or reports status)', (
    tester,
  ) async {
    const channel = MethodChannel('fah/calendar');
    final available = await channel.invokeMethod<bool>('isAvailable');
    print('[calendar] isAvailable=$available');
    final granted = await channel.invokeMethod<bool>('requestAccess');
    print('[calendar] requestAccess=$granted');
    final events = await channel.invokeMethod<List>('events', {
      'startMs': 0,
      'endMs': DateTime.now().millisecondsSinceEpoch,
    });
    print('[calendar] events=${events?.length}');
  });

  /// Recurring-event round trip against the real macOS calendar: create a
  /// weekly event with an alarm, list it back (the recurrence summary and
  /// alarms must ride the events map), then delete it with span "future".
  /// Needs calendar access — the TCC prompt is user-interactive, so this is
  /// a manual probe, not a CI test.
  testWidgets('calendar recurring-event round trip (manual probe)', (
    tester,
  ) async {
    const channel = MethodChannel('fah/calendar');
    final granted = await channel.invokeMethod<bool>('requestAccess');
    print('[calendar] requestAccess=$granted');
    if (granted != true) {
      print('[calendar] access not granted — skipping the round trip');
      return;
    }

    final calendars = await channel.invokeMethod<List>('calendars');
    print('[calendar] calendars=$calendars');

    final start = DateTime.now().add(const Duration(days: 1));
    final startMs = start.millisecondsSinceEpoch;
    final endMs = start.add(const Duration(hours: 1)).millisecondsSinceEpoch;
    const title = 'FA-PROBE recurring (delete me if left over)';
    final id = await channel.invokeMethod<String>('createEvent', {
      'title': title,
      'startMs': startMs,
      'endMs': endMs,
      'alarms': [10],
      'recurrence': {
        'frequency': 'weekly',
        'daysOfWeek': ['MO', 'WE', 'FR'],
        'count': 6,
      },
    });
    print('[calendar] created id=$id');
    expect(id, isNotNull, reason: 'createEvent failed');
    expect(id, isNotEmpty);

    final listed =
        (await channel.invokeMethod<List>('events', {
          'startMs': startMs,
          'endMs': start.add(const Duration(days: 1)).millisecondsSinceEpoch,
        }))?.cast<Map>() ??
        [];
    final probe = listed.where((event) => event['title'] == title).toList();
    print('[calendar] listed probe occurrences=${probe.length}');
    expect(probe, isNotEmpty, reason: 'the probe event did not list back');
    final recurrence = probe.first['recurrence'] as Map?;
    print('[calendar] recurrence=$recurrence alarms=${probe.first['alarms']}');
    expect(recurrence?['frequency'], 'weekly');
    expect((recurrence?['daysOfWeek'] as List?)?.cast<String>(), [
      'MO',
      'WE',
      'FR',
    ]);
    expect(recurrence?['count'], 6);
    expect(probe.first['alarms'], [10]);

    final deleted = await channel.invokeMethod<bool>('deleteEvent', {
      'id': id,
      'span': 'future',
    });
    print('[calendar] deleted (span future)=$deleted');
    expect(deleted, isTrue);

    final after =
        (await channel.invokeMethod<List>('events', {
          'startMs': startMs,
          'endMs': start.add(const Duration(days: 30)).millisecondsSinceEpoch,
        }))?.cast<Map>() ??
        [];
    expect(
      after.where((event) => event['title'] == title),
      isEmpty,
      reason: 'occurrences survived the span-future delete',
    );
  });
}
