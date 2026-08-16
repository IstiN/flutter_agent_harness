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
      expect(store.isConfigured('gemma'), isFalse);
    });

    test('markConfigured persists and round-trips', () async {
      final env = MemoryExecutionEnv();
      final store = await OnDeviceConfigStore.load(env);
      await store.markConfigured('gemma');
      expect(store.isConfigured('gemma'), isTrue);

      final reloaded = await OnDeviceConfigStore.load(env);
      expect(reloaded.configuredKinds, {'gemma'});
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
      await store.markConfigured('gemma');
      await store.markConfigured('gemma');
      await store.markConfigured('webllm');
      expect(notified, 2);
    });
  });
}
