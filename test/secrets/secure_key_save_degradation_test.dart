import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// In-memory [SecureKeyStore] whose write failure shape is configurable —
/// the macOS preflight throws the "no default keychain" StateError, the
/// generic path an exit-code tail (both classified by SecureKeyCache.save).
final class _ScriptedStore implements SecureKeyStore {
  _ScriptedStore();

  final map = <String, String>{};
  Object? writeError;

  @override
  String get label => 'fake store';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String?> read(String name) async => map[name];

  @override
  Future<void> write(String name, String value) async {
    final error = writeError;
    if (error != null) throw error;
    map[name] = value;
  }

  @override
  Future<void> delete(String name) async => map.remove(name);
}

void main() {
  group('SecureKeyCache failed-save name tracking (gh-1679 UT-2)', () {
    test('multiple failures keep every name, sorted, with per-name '
        'diagnostics', () async {
      final store = _ScriptedStore()
        ..writeError = StateError('keychain write failed (exit 45)');
      final cache = SecureKeyCache(store);
      await cache.probe();

      expect(await cache.save('FA_KEY_A', 'k1'), isFalse);
      expect(await cache.save('FA_KEY_B', 'k2'), isFalse);
      expect(await cache.save('FA_KEY_A', 'k3'), isFalse);

      expect(cache.failedSaveNames, ['FA_KEY_A', 'FA_KEY_B']);
      expect(
        cache.saveFailureDiagnostic('FA_KEY_A'),
        contains('keychain write failed (exit 45)'),
      );
      // The aggregate gh-1059 consumers keep working unchanged.
      expect(cache.saveFailures, 3);
      expect(cache.lastSaveError, contains('keychain write failed'));
    });

    test('a successful save clears the name; other names stay degraded',
        () async {
      final store = _ScriptedStore()
        ..writeError = StateError('keychain write failed (exit 45)');
      final cache = SecureKeyCache(store);
      await cache.probe();

      await cache.save('FA_KEY_A', 'k1');
      await cache.save('FA_KEY_B', 'k2');
      expect(cache.failedSaveNames, ['FA_KEY_A', 'FA_KEY_B']);

      store.writeError = null;
      expect(await cache.save('FA_KEY_A', 'k3'), isTrue);

      expect(cache.failedSaveNames, ['FA_KEY_B']);
      expect(cache.saveFailureDiagnostic('FA_KEY_A'), isNull);
      expect(cache.read('FA_KEY_A'), 'k3');
      // Counter semantics stay cumulative (gh-1059 /key status contract).
      expect(cache.saveFailures, 2);
    });

    test('the unavailable store degrades with the slot name too', () async {
      final store = _ScriptedStore();
      final cache = SecureKeyCache(store);

      expect(await cache.save('FA_KEY_A', 'k1'), isFalse);
      expect(cache.failedSaveNames, ['FA_KEY_A']);
      expect(
        cache.saveFailureDiagnostic('FA_KEY_A'),
        contains('secure store unavailable'),
      );
    });
  });

  group('macOS missing-default-keychain advisory (gh-1679 UT-4, AC6)',
      () {
    test('classifies the preflight failure shape', () {
      expect(
        isMissingDefaultKeychainError('no default keychain (exit 1)'),
        isTrue,
      );
      expect(
        isMissingDefaultKeychainError('keychain write failed (exit 45)'),
        isFalse,
      );
    });

    test('the advisory names the system remedy and is text-only', () {
      final advisory = missingDefaultKeychainAdvisory();
      // The remedy command is named, never executed (pure string).
      expect(
        advisory,
        contains(
          'security default-keychain -s ~/Library/Keychains/login.keychain-db',
        ),
      );
      expect(advisory, startsWith('note:'));
    });
  });
}
