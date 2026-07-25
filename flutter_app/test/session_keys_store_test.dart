import 'package:fa/services/session_keys_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
