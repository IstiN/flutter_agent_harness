// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/launcher_layout_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LauncherLayoutStore', () {
    test(
      'syncApps seeds defaults: apps in order + system tiles, no folders',
      () {
        final store = LauncherLayoutStore.inMemory();
        store.syncApps(['weather', 'calculator']);
        expect(store.topLevelKeys, [
          'app:weather',
          'app:calculator',
          LauncherLayoutStore.settingsKey,
          LauncherLayoutStore.filesKey,
        ]);
      },
    );

    test('syncApps appends new apps, prunes deleted ones, keeps order', () {
      final store = LauncherLayoutStore.inMemory();
      store.syncApps(['a', 'b', 'c']);
      store.reorder(2, 0); // c first
      store.syncApps(['c', 'a', 'd']); // b deleted, d new
      expect(store.topLevelKeys, [
        'app:c',
        'app:a',
        LauncherLayoutStore.settingsKey,
        LauncherLayoutStore.filesKey,
        'app:d',
      ]);
    });

    test('syncApps prunes folder tiles and dissolves emptied folders', () {
      final store = LauncherLayoutStore.inMemory();
      store.syncApps(['a', 'b']);
      final id = store.createFolder('app:a', 'app:b', name: 'Pair')!;
      expect(store.folderById(id), isNotNull);
      store.syncApps(['a']); // b deleted → folder keeps a
      expect(store.folderById(id)!.tiles, ['app:a']);
      store.syncApps([]); // both gone → folder dissolved
      expect(store.folderById(id), isNull);
      expect(store.topLevelKeys, [
        LauncherLayoutStore.settingsKey,
        LauncherLayoutStore.filesKey,
      ]);
    });

    test('reorder moves the entry to the target index', () {
      final store = LauncherLayoutStore.inMemory(
        order: ['app:a', 'app:b', 'app:c', 'app:d'],
      );
      store.reorder(0, 2);
      expect(store.topLevelKeys, ['app:b', 'app:c', 'app:a', 'app:d']);
      store.reorder(3, 0);
      expect(store.topLevelKeys, ['app:d', 'app:b', 'app:c', 'app:a']);
      // Out-of-range and no-op moves are ignored.
      store.reorder(-1, 2);
      store.reorder(0, 9);
      expect(store.topLevelKeys, ['app:d', 'app:b', 'app:c', 'app:a']);
    });

    test('createFolder replaces both tiles at the first tile position', () {
      final store = LauncherLayoutStore.inMemory(
        order: ['app:a', 'app:b', 'app:c'],
      );
      final id = store.createFolder('app:c', 'app:a', name: 'Tools');
      expect(id, isNotNull);
      expect(store.topLevelKeys, ['app:b', LauncherLayoutStore.folderKey(id!)]);
      final folder = store.folderById(id)!;
      expect(folder.name, 'Tools');
      expect(folder.tiles, ['app:c', 'app:a']);
    });

    test('createFolder rejects system tiles, folders and unknown keys', () {
      final store = LauncherLayoutStore.inMemory(
        order: ['app:a', LauncherLayoutStore.settingsKey],
      );
      expect(
        store.createFolder('app:a', LauncherLayoutStore.settingsKey, name: 'x'),
        isNull,
      );
      expect(store.createFolder('app:a', 'app:missing', name: 'x'), isNull);
      expect(store.createFolder('app:a', 'app:a', name: 'x'), isNull);
    });

    test('addToFolder moves a top-level tile into the folder', () {
      final store = LauncherLayoutStore.inMemory(
        order: ['app:a', 'app:b', 'app:c'],
      );
      final id = store.createFolder('app:a', 'app:b', name: 'Pair')!;
      store.addToFolder(id, 'app:c');
      expect(store.folderById(id)!.tiles, ['app:a', 'app:b', 'app:c']);
      expect(store.topLevelKeys, [LauncherLayoutStore.folderKey(id)]);
      // System tiles cannot be filed away.
      store.addToFolder(id, LauncherLayoutStore.settingsKey);
      expect(store.folderById(id)!.tiles, hasLength(3));
    });

    test('removeFromFolder re-inserts right after the folder entry', () {
      final store = LauncherLayoutStore.inMemory(
        order: ['app:x', 'app:a', 'app:b', 'app:c'],
      );
      final id = store.createFolder('app:a', 'app:b', name: 'Pair')!;
      store.addToFolder(id, 'app:c');
      store.removeFromFolder(id, 'app:b');
      expect(store.folderById(id)!.tiles, ['app:a', 'app:c']);
      expect(store.topLevelKeys, [
        'app:x',
        LauncherLayoutStore.folderKey(id),
        'app:b',
      ]);
    });

    test('removing the last folder tile dissolves the folder in place', () {
      final store = LauncherLayoutStore.inMemory(order: ['app:a', 'app:b']);
      final id = store.createFolder('app:a', 'app:b', name: 'Pair')!;
      store.removeFromFolder(id, 'app:a');
      store.removeFromFolder(id, 'app:b');
      expect(store.folderById(id), isNull);
      expect(store.topLevelKeys, ['app:b', 'app:a']);
    });

    test('renameFolder trims and ignores blank/unchanged names', () {
      final store = LauncherLayoutStore.inMemory(order: ['app:a', 'app:b']);
      final id = store.createFolder('app:a', 'app:b', name: 'Pair')!;
      store.renameFolder(id, '  Stuff  ');
      expect(store.folderById(id)!.name, 'Stuff');
      store.renameFolder(id, '   ');
      expect(store.folderById(id)!.name, 'Stuff');
    });

    test('dissolveFolder splices the tiles at the folder position', () {
      final store = LauncherLayoutStore.inMemory(
        order: ['app:x', 'app:a', 'app:b', 'app:y'],
      );
      final id = store.createFolder('app:a', 'app:b', name: 'Pair')!;
      store.dissolveFolder(id);
      expect(store.folderById(id), isNull);
      expect(store.topLevelKeys, ['app:x', 'app:a', 'app:b', 'app:y']);
      store.dissolveFolder('nope'); // unknown id: no-op
      expect(store.topLevelKeys, hasLength(4));
    });

    test('mutations notify listeners', () {
      final store = LauncherLayoutStore.inMemory(order: ['app:a', 'app:b']);
      var notified = 0;
      store.addListener(() => notified++);
      store.syncApps(['a', 'b', 'c']);
      store.reorder(0, 1);
      store.renameFolder('missing', 'x'); // no notify
      expect(notified, 2);
    });

    test('persists and reloads the layout through the env', () async {
      final env = MemoryExecutionEnv();
      final store = await LauncherLayoutStore.load(env);
      store.syncApps(['a', 'b', 'c']);
      final id = store.createFolder('app:a', 'app:b', name: 'Pair')!;
      store.renameFolder(id, 'Stuff');
      // Saves are fire-and-forget — let the write land.
      await Future<void>.delayed(Duration.zero);

      final reloaded = await LauncherLayoutStore.load(env);
      expect(reloaded.topLevelKeys, store.topLevelKeys);
      expect(reloaded.folderById(id)!.name, 'Stuff');
      expect(reloaded.folderById(id)!.tiles, ['app:a', 'app:b']);
    });

    test('corrupt file loads empty (defaults rebuild via syncApps)', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/${LauncherLayoutStore.fileName}',
        'not json {{{',
      );
      final store = await LauncherLayoutStore.load(env);
      expect(store.topLevelKeys, isEmpty);
      store.syncApps(['a']);
      expect(store.topLevelKeys.first, 'app:a');
    });

    test('dangling folder reference in order loads as corrupt', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/${LauncherLayoutStore.fileName}',
        '{"version":1,"order":["folder:ghost"],"folders":[]}',
      );
      final store = await LauncherLayoutStore.load(env);
      expect(store.topLevelKeys, isEmpty);
    });

    test('wrong schema version loads empty', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/${LauncherLayoutStore.fileName}',
        '{"version":99,"order":["app:a"],"folders":[]}',
      );
      final store = await LauncherLayoutStore.load(env);
      expect(store.topLevelKeys, isEmpty);
    });
  });
}
