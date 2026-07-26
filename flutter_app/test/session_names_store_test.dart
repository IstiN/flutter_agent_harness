// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/session_names_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionNamesStore', () {
    test('starts empty; inMemory seed is served', () {
      final empty = SessionNamesStore.inMemory();
      expect(empty.titleFor('abc'), isNull);

      final seeded = SessionNamesStore.inMemory({'abc': 'My chat'});
      expect(seeded.titleFor('abc'), 'My chat');
    });

    test('rename notifies and stores; blank title clears', () async {
      final store = SessionNamesStore.inMemory();
      var notified = 0;
      store.addListener(() => notified++);

      await store.rename('abc', '  My chat  ');
      expect(store.titleFor('abc'), 'My chat');
      expect(notified, 1);

      // Re-setting the same title is a no-op.
      await store.rename('abc', 'My chat');
      expect(notified, 1);

      await store.rename('abc', '   ');
      expect(store.titleFor('abc'), isNull);
      expect(notified, 2);

      // Clearing an absent entry is a no-op.
      await store.rename('abc');
      expect(notified, 2);
    });

    test('missing file loads as empty', () async {
      final env = MemoryExecutionEnv();
      final store = await SessionNamesStore.load(env);
      expect(store.titleFor('abc'), isNull);
    });

    test('corrupt file loads as empty instead of crashing', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/session_names.json', 'not json {');
      final store = await SessionNamesStore.load(env);
      expect(store.titleFor('abc'), isNull);
    });

    test('wrong schema version loads as empty', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/session_names.json',
        '{"version": 99, "names": {"abc": "x"}}',
      );
      final store = await SessionNamesStore.load(env);
      expect(store.titleFor('abc'), isNull);
    });

    test('titles round-trip through the env filesystem', () async {
      final env = MemoryExecutionEnv();
      final store = await SessionNamesStore.load(env);
      await store.rename('session-one', 'First chat');
      await store.rename('session-two', 'Second chat');

      final reloaded = await SessionNamesStore.load(env);
      expect(reloaded.titleFor('session-one'), 'First chat');
      expect(reloaded.titleFor('session-two'), 'Second chat');

      await reloaded.rename('session-one');
      final again = await SessionNamesStore.load(env);
      expect(again.titleFor('session-one'), isNull);
      expect(again.titleFor('session-two'), 'Second chat');
    });
  });
}
