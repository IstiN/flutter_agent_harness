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
}
