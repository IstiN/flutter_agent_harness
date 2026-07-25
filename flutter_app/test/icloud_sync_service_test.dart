// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:fa/services/icloud_sync_service.dart';
import 'package:fa/services/icloud_sync_service_io.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sync engine talks `dart:io` to the container side, so the tests run
/// the env side on a real temp directory too ([LocalExecutionEnv]) — that
/// is the only way to control file mtimes, which drive the last-write-wins
/// policy.
void main() {
  late Directory tmp;
  late Directory srcRoot;
  late Directory faSyncRoot;
  late LocalExecutionEnv env;

  final tOld = DateTime(2026, 1, 1, 12);
  final tNew = DateTime(2026, 6, 1, 12);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('icloud_sync_test');
    srcRoot = Directory('${tmp.path}/src')..createSync();
    faSyncRoot = Directory('${tmp.path}/container/Documents/FaSync');
    env = LocalExecutionEnv(cwd: srcRoot.path);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  File hostFile(String rel) => File('${faSyncRoot.path}/$rel');

  Future<void> writeEnv(String rel, String content, DateTime mtime) async {
    await env.writeFile(rel, content);
    await File('${srcRoot.path}/$rel').setLastModified(mtime);
  }

  Future<void> writeHost(String rel, String content, DateTime mtime) async {
    final file = hostFile(rel);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    await file.setLastModified(mtime);
  }

  ICloudSyncEngine engine() =>
      ICloudSyncEngine(env: env, faSyncRoot: faSyncRoot.path);

  group('ICloudSyncEngine', () {
    test('pushes env-only sessions/apps trees into the container', () async {
      await writeEnv('sessions/s1/chat.jsonl', '{"msg":"hi"}\n', tOld);
      await writeEnv('apps/weather/widget.js', 'render()', tNew);

      final report = await engine().sync();

      expect(report.filesCopied, 2);
      expect(
        hostFile('sessions/s1/chat.jsonl').readAsStringSync(),
        '{"msg":"hi"}\n',
      );
      expect(hostFile('apps/weather/widget.js').readAsStringSync(), 'render()');
      // Pushes preserve the source mtime, so the next sync sees equal sides.
      expect(
        hostFile(
          'sessions/s1/chat.jsonl',
        ).statSync().modified.millisecondsSinceEpoch,
        tOld.millisecondsSinceEpoch,
      );
    });

    test('pulls container-only files into the env', () async {
      await writeHost('sessions/s2/notes.json', '[1,2]', tOld);

      final report = await engine().sync();

      expect(report.filesCopied, 1);
      final pulled = await env.readTextFile('sessions/s2/notes.json');
      expect(pulled.valueOrNull, '[1,2]');
    });

    test('last-write-wins: newer env file overwrites the container', () async {
      await writeEnv('sessions/s1/chat.jsonl', 'env-new', tNew);
      await writeHost('sessions/s1/chat.jsonl', 'container-old', tOld);

      final report = await engine().sync();

      expect(report.filesCopied, 1);
      expect(hostFile('sessions/s1/chat.jsonl').readAsStringSync(), 'env-new');
    });

    test('last-write-wins: newer container file overwrites the env', () async {
      await writeEnv('sessions/s1/chat.jsonl', 'env-old', tOld);
      await writeHost('sessions/s1/chat.jsonl', 'container-new', tNew);

      final report = await engine().sync();

      expect(report.filesCopied, 1);
      final pulled = await env.readTextFile('sessions/s1/chat.jsonl');
      expect(pulled.valueOrNull, 'container-new');
    });

    test('equal mtimes are treated as in sync (nothing copied)', () async {
      await writeEnv('sessions/s1/chat.jsonl', 'same', tOld);
      await writeHost('sessions/s1/chat.jsonl', 'same', tOld);

      final report = await engine().sync();

      expect(report.filesCopied, 0);
      expect(report.bytesCopied, 0);
    });

    test('persists the last-sync state via the env', () async {
      final at = DateTime(2026, 7, 25, 19, 12);
      await writeEnv('apps/calc/widget.js', 'x', tOld);

      final report = await ICloudSyncEngine(
        env: env,
        faSyncRoot: faSyncRoot.path,
        now: () => at,
      ).sync();

      expect(report.syncedAt, at);
      expect(await readICloudSyncState(env), at);
      final state = File('${srcRoot.path}/$icloudSyncStateFile');
      expect(state.existsSync(), isTrue);
      expect(state.readAsStringSync(), contains('"filesCopied":1'));
    });

    test('a second sync after settling copies nothing', () async {
      await writeEnv('sessions/s1/chat.jsonl', 'data', tOld);
      await engine().sync();

      final report = await engine().sync();

      expect(report.filesCopied, 0);
    });
  });

  group('MethodChannelICloudSyncService', () {
    test('isAvailable follows the container resolution', () async {
      final unavailable = MethodChannelICloudSyncService(
        env,
        containerPath: () async => null,
      );
      expect(await unavailable.isAvailable(), isFalse);
      expect(await unavailable.containerUrl(), isNull);

      final available = MethodChannelICloudSyncService(
        env,
        containerPath: () async => '${tmp.path}/container/Documents',
      );
      expect(await available.isAvailable(), isTrue);
    });

    test('syncNow throws when the container is unavailable', () async {
      final service = MethodChannelICloudSyncService(
        env,
        containerPath: () async => null,
      );
      await expectLater(service.syncNow(), throwsStateError);
    });

    test('syncNow merges through the injected container path', () async {
      await writeEnv('sessions/s1/chat.jsonl', 'data', tOld);
      final service = MethodChannelICloudSyncService(
        env,
        containerPath: () async => '${tmp.path}/container/Documents',
      );

      final report = await service.syncNow();

      expect(report.filesCopied, 1);
      expect(await service.lastSyncAt(), isNotNull);
    });

    test('lastSyncAt is null before the first sync', () async {
      final service = MethodChannelICloudSyncService(
        env,
        containerPath: () async => '${tmp.path}/container/Documents',
      );
      expect(await service.lastSyncAt(), isNull);
    });
  });
}
