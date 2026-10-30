// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/ondevice_config_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OnDeviceConfigStore', () {
    test('missing file loads as empty', () async {
      final store = await OnDeviceConfigStore.load(MemoryExecutionEnv());
      expect(store.configuredKinds, isEmpty);
      expect(store.isConfigured('webllm'), isFalse);
    });

    test('markConfigured persists and round-trips', () async {
      final env = MemoryExecutionEnv();
      final store = await OnDeviceConfigStore.load(env);
      await store.markConfigured('webllm');
      expect(store.isConfigured('webllm'), isTrue);

      final reloaded = await OnDeviceConfigStore.load(env);
      expect(reloaded.configuredKinds, {'webllm'});
    });

    test('a corrupt file loads as empty instead of crashing', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/${OnDeviceConfigStore.fileName}',
        'not json {',
      );
      final store = await OnDeviceConfigStore.load(env);
      expect(store.configuredKinds, isEmpty);
    });

    test('markConfigured notifies listeners once per kind', () async {
      final store = OnDeviceConfigStore.inMemory();
      var notified = 0;
      store.addListener(() => notified++);
      await store.markConfigured('webllm');
      await store.markConfigured('webllm');
      await store.markConfigured('transformers_js');
      expect(notified, 2);
    });

    test('a persisted gema kind resets silently on load (gh-2004)', () async {
      final env = MemoryExecutionEnv();
      // A pre-removal store: the user once configured the gema engine
      // (plus the surviving on-device engines).
      await env.writeFile(
        '${env.cwd}/${OnDeviceConfigStore.fileName}',
        '{"version": 1, "kinds": ["webllm", "gemma", "transformers_js"]}',
      );

      final store = await OnDeviceConfigStore.load(env);

      // The removed kind is dropped (its provider rows can never come
      // back on this build); the surviving kinds stay.
      expect(store.isConfigured('gemma'), isFalse);
      expect(store.isConfigured('webllm'), isTrue);
      expect(store.isConfigured('transformers_js'), isTrue);
      // Unknown/removed kinds never re-persist (tolerant parse, no
      // migration logic — the next markConfigured write carries only the
      // surviving kinds).
      await store.markConfigured('webllm'); // no-op: already present
      expect(store.configuredKinds, {'webllm', 'transformers_js'});
    });

    test('markConfigured refuses removed kinds (gemma cannot come back)',
        () async {
      final store = OnDeviceConfigStore.inMemory();
      await store.markConfigured('gemma');
      expect(store.isConfigured('gemma'), isFalse);
      expect(store.configuredKinds, isEmpty);
    });
  });
}
