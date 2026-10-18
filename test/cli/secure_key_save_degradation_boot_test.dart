import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

/// In-memory [SecureKeyStore] with a toggleable write failure.
final class _MapStore implements SecureKeyStore {
  _MapStore();

  bool failWrites = false;
  final map = <String, String>{};

  @override
  String get label => 'fake store';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String?> read(String name) async => map[name];

  @override
  Future<void> write(String name, String value) async {
    if (failWrites) throw StateError('keychain write failed (exit 45)');
    map[name] = value;
  }

  @override
  Future<void> delete(String name) async => map.remove(name);
}

void main() {
  group('secureKeySaveDegradationLines (gh-1679 UT-2, IT-2, AC2)', () {
    test('boot with no failures and no flagged entries prints nothing new',
        () async {
      final keys = SecureKeyCache(_MapStore());
      await keys.probe();

      expect(
        secureKeySaveDegradationLines(keys: keys, customProviders: const []),
        isEmpty,
      );
    });

    test('in-process failed saves print one line per slot with the last '
        'error and the retry command', () async {
      final store = _MapStore()..failWrites = true;
      final keys = SecureKeyCache(store);
      await keys.probe();

      await keys.save('FA_KEY_B', 'sk-value-b');
      await keys.save('FA_KEY_A', 'sk-value-a');

      final lines = secureKeySaveDegradationLines(
        keys: keys,
        customProviders: const [],
      );
      expect(lines, hasLength(2));
      // One line per affected slot, sorted; the retry command names it.
      expect(lines[0], contains('FA_KEY_A'));
      expect(lines[1], contains('FA_KEY_B'));
      for (final line in lines) {
        expect(line, contains('fake store'));
        expect(line, contains('keychain write failed (exit 45)'));
        expect(line, contains('/key set'));
        expect(line, contains('<value>'));
        // AC4 byte-scan: slots and diagnostics only, never values.
        expect(line, isNot(contains('sk-value-a')));
        expect(line, isNot(contains('sk-value-b')));
      }
    });

    test('a wizard-flagged entry whose slot is still empty prints the '
        'degradation line on the next boot', () async {
      final keys = SecureKeyCache(_MapStore());
      await keys.probe();
      final entry = CustomProviderEntry(
        name: 'kimi_ira',
        apiType: 'openai',
        baseUrl: 'https://api.kimi.com/coding/v1',
        modelId: 'k2',
        keyName: 'FA_KEY_API_KIMI_COM_KIMI_IRA',
        keyNotPersisted: true,
      );

      final lines = secureKeySaveDegradationLines(
        keys: keys,
        customProviders: [entry],
      );
      expect(lines, hasLength(1));
      expect(lines.single, contains('FA_KEY_API_KIMI_COM_KIMI_IRA'));
      expect(lines.single, contains('/key set FA_KEY_API_KIMI_COM_KIMI_IRA'));
    });

    test('a flagged entry whose slot resolved prints nothing (the failure '
        'generation ended)', () async {
      final store = _MapStore();
      final keys = SecureKeyCache(store);
      await keys.probe();
      await keys.save('FA_KEY_API_KIMI_COM_KIMI_IRA', 'sk-ira-key');
      final entry = CustomProviderEntry(
        name: 'kimi_ira',
        apiType: 'openai',
        baseUrl: 'https://api.kimi.com/coding/v1',
        modelId: 'k2',
        keyName: 'FA_KEY_API_KIMI_COM_KIMI_IRA',
        keyNotPersisted: true,
      );

      expect(
        secureKeySaveDegradationLines(
          keys: keys,
          customProviders: [entry],
        ),
        isEmpty,
      );
    });

    test('a successful save clears the in-process name from the boot note',
        () async {
      final store = _MapStore()..failWrites = true;
      final keys = SecureKeyCache(store);
      await keys.probe();
      await keys.save('FA_KEY_A', 'sk-value-a');
      expect(keys.failedSaveNames, ['FA_KEY_A']);

      store.failWrites = false;
      await keys.save('FA_KEY_A', 'sk-value-a');
      expect(
        secureKeySaveDegradationLines(
          keys: keys,
          customProviders: const [],
        ),
        isEmpty,
      );
    });
  });

  group('CustomProviderEntry.keyNotPersisted yaml round-trip (gh-1679)', () {
    test('the flag survives a yaml round-trip; unset stays byte-absent',
        () {
      final flagged = CustomProviderEntry(
        name: 'kimi_ira',
        apiType: 'openai',
        baseUrl: 'https://api.kimi.com/coding/v1',
        modelId: 'k2',
        keyName: 'FA_KEY_API_KIMI_COM_KIMI_IRA',
        keyNotPersisted: true,
      );
      final parsed = CustomProviderEntry.fromYaml(flagged.toYaml());
      expect(parsed.keyNotPersisted, isTrue);
      expect(parsed.keyName, 'FA_KEY_API_KIMI_COM_KIMI_IRA');

      final plain = CustomProviderEntry(
        name: 'kimi_me',
        apiType: 'openai',
        baseUrl: 'https://api.kimi.com/coding/v1',
        modelId: 'k2',
        keyName: 'FA_KEY_API_KIMI_COM_KIMI_ME',
      );
      expect(plain.toYaml(), isNot(contains('keyNotPersisted')));
      expect(CustomProviderEntry.fromYaml(plain.toYaml()).keyNotPersisted,
          isFalse);
    });
  });
}
