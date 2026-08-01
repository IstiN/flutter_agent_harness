import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionKeysStore', () {
    test('starts empty; inMemory seed is listed sorted', () {
      final empty = SessionKeysStore.inMemory();
      expect(empty.names, isEmpty);

      final seeded = SessionKeysStore.inMemory({
        'HUGGINGFACE_TOKEN': 'hf_x',
        'OPENROUTER_API_KEY': 'sk-or-x',
      });
      expect(seeded.names, ['HUGGINGFACE_TOKEN', 'OPENROUTER_API_KEY']);
      expect(seeded.has('OPENROUTER_API_KEY'), isTrue);
      expect(seeded.valueOf('HUGGINGFACE_TOKEN'), 'hf_x');
      expect(seeded.has('UNKNOWN'), isFalse);
    });

    test('set notifies and stores; empty value deletes', () async {
      final store = SessionKeysStore.inMemory();
      var notified = 0;
      store.addListener(() => notified++);

      await store.set('OPENROUTER_API_KEY', 'sk-or-1');
      expect(store.valueOf('OPENROUTER_API_KEY'), 'sk-or-1');
      expect(notified, 1);

      // Re-setting the same value is a no-op.
      await store.set('OPENROUTER_API_KEY', 'sk-or-1');
      expect(notified, 1);

      await store.set('OPENROUTER_API_KEY', '');
      expect(store.has('OPENROUTER_API_KEY'), isFalse);
      expect(notified, 2);
    });

    test('delete notifies only when the entry existed', () async {
      final store = SessionKeysStore.inMemory({'A': '1'});
      var notified = 0;
      store.addListener(() => notified++);

      await store.delete('MISSING');
      expect(notified, 0);

      await store.delete('A');
      expect(store.has('A'), isFalse);
      expect(notified, 1);
    });

    test('missing file loads as empty', () async {
      final env = MemoryExecutionEnv();
      final store = await SessionKeysStore.load(env);
      expect(store.names, isEmpty);
    });

    test('corrupt file loads as empty instead of crashing', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/session_keys.json', 'not json {');
      final store = await SessionKeysStore.load(env);
      expect(store.names, isEmpty);
    });

    test('wrong schema version loads as empty', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/session_keys.json',
        '{"version": 99, "keys": {"A": "1"}}',
      );
      final store = await SessionKeysStore.load(env);
      expect(store.names, isEmpty);
    });

    test('non-string values are dropped on load', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/session_keys.json',
        '{"version": 1, "keys": {"A": "1", "B": 42}}',
      );
      final store = await SessionKeysStore.load(env);
      expect(store.names, ['A']);
    });

    test('keys round-trip through the env filesystem', () async {
      final env = MemoryExecutionEnv();
      final store = await SessionKeysStore.load(env);
      await store.set('OPENROUTER_API_KEY', 'sk-or-secret');
      await store.set('HUGGINGFACE_TOKEN', 'hf_secret');

      final reloaded = await SessionKeysStore.load(env);
      expect(reloaded.names, ['HUGGINGFACE_TOKEN', 'OPENROUTER_API_KEY']);
      expect(reloaded.valueOf('OPENROUTER_API_KEY'), 'sk-or-secret');

      await reloaded.delete('HUGGINGFACE_TOKEN');
      final again = await SessionKeysStore.load(env);
      expect(again.names, ['OPENROUTER_API_KEY']);
    });
  });

  group('SessionKeysStore with a Keychain backend', () {
    const channel = MethodChannel('fah/keychain');
    final backend = <String, String>{};

    setUp(() {
      backend.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'isAvailable':
                return true;
              case 'readAll':
                return Map<String, String>.of(backend);
              case 'set':
                backend[call.arguments['name'] as String] =
                    call.arguments['value'] as String;
                return true;
              case 'delete':
                backend.remove(call.arguments['name'] as String);
                return true;
            }
            return null;
          });
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('reads and writes go to the Keychain, not the file', () async {
      backend['OPENROUTER_API_KEY'] = 'sk-secure';
      final env = MemoryExecutionEnv();
      final store = await SessionKeysStore.load(
        env,
        keychain: const KeychainStore(),
      );
      expect(store.usesKeychain, isTrue);
      expect(store.valueOf('OPENROUTER_API_KEY'), 'sk-secure');

      await store.set('HUGGINGFACE_TOKEN', 'hf-secure');
      expect(backend['HUGGINGFACE_TOKEN'], 'hf-secure');
      // Nothing is written to the plaintext file on this backend.
      expect(
        (await env.readTextFile('${env.cwd}/session_keys.json')).valueOrNull,
        isNull,
      );

      await store.delete('OPENROUTER_API_KEY');
      expect(backend.containsKey('OPENROUTER_API_KEY'), isFalse);
    });

    test('file-persisted keys migrate into the Keychain once', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/session_keys.json',
        '{"version": 1, "keys": {"OPENROUTER_API_KEY": "sk-file"}}',
      );
      final store = await SessionKeysStore.load(
        env,
        keychain: const KeychainStore(),
      );
      expect(store.valueOf('OPENROUTER_API_KEY'), 'sk-file');
      expect(backend['OPENROUTER_API_KEY'], 'sk-file');

      // Later boots read the Keychain, so a file edit no longer matters.
      await env.writeFile(
        '${env.cwd}/session_keys.json',
        '{"version": 1, "keys": {"OPENROUTER_API_KEY": "sk-changed"}}',
      );
      final reloaded = await SessionKeysStore.load(
        env,
        keychain: const KeychainStore(),
      );
      expect(reloaded.valueOf('OPENROUTER_API_KEY'), 'sk-file');
    });
  });
}
