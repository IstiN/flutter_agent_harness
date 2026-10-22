// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Unit tests for the gh-1745 request-blob spill: the heavy per-request
/// payloads (per-message summaries and raw wire dumps) leave the primary
/// session JSONL and land in `.fah/trajectories/<sid>/requests/` under a
/// TTL / max-bytes rotation policy, while the `model_request_summary`
/// record keeps lightweight metadata plus a `spillFile` pointer.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

TrajectoryRequestDetail _detail({
  int messages = 3,
  int blockChars = 64,
  String? wireDumpHash,
}) => TrajectoryRequestDetail(
  messageCount: messages,
  systemPromptChars: 1200,
  toolCount: 2,
  toolNames: const ['read', 'bash'],
  wireDumpHash: wireDumpHash,
  messages: [
    for (var i = 0; i < messages; i++)
      TrajectoryRequestMessageSummary(
        role: i.isEven ? 'user' : 'assistant',
        chars: 1000 + i,
        preview: 'message $i preview ${'x' * 40}',
        blocks: [
          TrajectoryRequestMessageBlock(
            type: 'text',
            chars: blockChars,
            text: 'y' * blockChars,
          ),
        ],
      ),
  ],
);

/// An env whose `writeBinaryFile` fails every call — the AC6 degradation
/// probe (a failed spill write must fall back inline, never crash).
final class _FailWritesEnv implements ExecutionEnv {
  _FailWritesEnv(this._delegate);

  final MemoryExecutionEnv _delegate;
  var writeCalls = 0;

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) async {
    writeCalls++;
    return const Err(
      FileError(FileErrorCode.unknown, 'injected write failure'),
    );
  }

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  group('stripTrajectoryRequestDetail (gh-1745)', () {
    test('keeps sizes and counts, drops previews and block texts', () {
      final detail = _detail();
      final stripped = stripTrajectoryRequestDetail(
        detail,
        spillFile: '.fah/trajectories/s1/requests/1.json',
      );
      expect(stripped.messageCount, detail.messageCount);
      expect(stripped.systemPromptChars, detail.systemPromptChars);
      expect(stripped.toolCount, detail.toolCount);
      expect(stripped.toolNames, detail.toolNames);
      expect(stripped.spillFile, '.fah/trajectories/s1/requests/1.json');
      // Every message degrades to a role+chars stub: the inputChars
      // estimation basis (Σ chars) stays truthful.
      for (var i = 0; i < stripped.messages.length; i++) {
        expect(stripped.messages[i].role, detail.messages[i].role);
        expect(stripped.messages[i].chars, detail.messages[i].chars);
        expect(stripped.messages[i].preview, isEmpty);
        expect(stripped.messages[i].blocks, isEmpty);
      }
      // The full detail is untouched.
      expect(detail.messages.first.blocks, isNotEmpty);
    });

    test('wireDumpHash override stamps the spilled dump pointer', () {
      final stripped = stripTrajectoryRequestDetail(
        _detail(),
        spillFile: 'f',
        wireDumpHash: 'abcd1234abcd1234',
      );
      expect(stripped.wireDumpHash, 'abcd1234abcd1234');
      // Without an override the existing pointer passes through.
      expect(
        stripTrajectoryRequestDetail(
          _detail(wireDumpHash: 'feedfeedfeedfeed'),
          spillFile: 'f',
        ).wireDumpHash,
        'feedfeedfeedfeed',
      );
    });

    test('round-trips through JSON (the replay fold)', () {
      final stripped = stripTrajectoryRequestDetail(
        _detail(),
        spillFile: '.fah/trajectories/s1/requests/7.json',
      );
      final restored = TrajectoryRequestDetail.fromJson(stripped.toJson());
      expect(restored.spillFile, stripped.spillFile);
      expect(restored.messages.first.role, stripped.messages.first.role);
      expect(restored.messages.first.blocks, isEmpty);
    });
  });

  group('TrajectoryRequestBlobStore', () {
    late MemoryExecutionEnv env;

    setUp(() => env = MemoryExecutionEnv(cwd: '/work'));

    TrajectoryRequestBlobStore store({
      String? Function()? sessionId,
      int maxBytes = trajectoryRequestBlobMaxBytes,
      int ttlDays = trajectoryRequestBlobTtlDays,
      DateTime Function()? clock,
    }) => TrajectoryRequestBlobStore(
      env: env,
      sessionId: sessionId ?? () => 's1',
      maxBytes: maxBytes,
      ttlDays: ttlDays,
      clock: clock,
    );

    test(
      'write lands a JSON blob under .fah/trajectories/<sid>/requests/',
      () async {
        final spill = await store().write(detail: _detail());
        expect(spill, isNotNull);
        expect(spill!.file, '.fah/trajectories/s1/requests/1.json');
        expect(spill.wireDumpHash, isNull);
        final read = await env.readTextFile(spill.file);
        final decoded = jsonDecode(read.valueOrNull!) as Map;
        expect(decoded.containsKey('detail'), isTrue);
        final restored = TrajectoryRequestDetail.fromJson(
          (decoded['detail'] as Map).cast<String, dynamic>(),
        );
        // The blob carries the FULL detail (previews + blocks).
        expect(restored.messages.first.preview, isNotEmpty);
        expect(restored.messages.first.blocks, isNotEmpty);
      },
    );

    test('write with a raw wire dump stores it and reports the hash', () async {
      final spill = await store().write(
        detail: _detail(),
        rawWireDump: '{"model":"m","messages":[]}',
      );
      expect(spill!.wireDumpHash, isNotNull);
      final dump = await store().readWireDump(spill.file);
      expect(dump, isNotNull);
      expect(dump!.hash, spill.wireDumpHash);
      expect(dump.payload, contains('"model"'));
    });

    test('readDetail round-trips; a missing file degrades to null', () async {
      final spill = await store().write(detail: _detail(messages: 2));
      final detail = await store().readDetail(spill!.file);
      expect(detail, isNotNull);
      expect(detail!.messageCount, 2);
      expect(
        await store().readDetail('.fah/trajectories/s1/requests/99.json'),
        isNull,
      );
    });

    test('sequence numbers resume past existing files (no overwrite on '
        'process restart)', () async {
      await env.writeFile(
        '.fah/trajectories/s1/requests/4.json',
        '{"detail":{}}',
      );
      final spill = await store().write(detail: _detail());
      expect(spill!.file, '.fah/trajectories/s1/requests/5.json');
    });

    test('a missing session id spills to the sessionless dir', () async {
      final spill = await store(sessionId: () => null).write(detail: _detail());
      expect(spill!.file, startsWith('.fah/trajectories/sessionless/'));
    });

    test('a failed spill write degrades to null (inline fallback)', () async {
      final failing = _FailWritesEnv(env);
      final spill = await TrajectoryRequestBlobStore(
        env: failing,
        sessionId: () => 's1',
      ).write(detail: _detail());
      expect(spill, isNull);
      expect(failing.writeCalls, 1);
    });

    test(
      'rotation deletes oldest blobs beyond the per-session byte budget',
      () async {
        final s = store(maxBytes: 1);
        // Each blob exceeds the 1-byte budget, so every write sweeps the
        // dir down to just the newest file.
        await s.write(detail: _detail());
        await s.write(detail: _detail());
        final spill = await s.write(detail: _detail());
        expect(spill!.file, endsWith('3.json'));
        final listing = await env.listDir('.fah/trajectories/s1/requests');
        expect(listing.valueOrNull!.map((f) => f.name).toList(), ['3.json']);
      },
    );

    test(
      'rotation keeps files within the budget when blobs are small',
      () async {
        final s = store(maxBytes: 100000);
        final small = TrajectoryRequestDetail(
          messageCount: 1,
          systemPromptChars: 0,
          toolCount: 0,
          toolNames: const [],
          messages: const [],
        );
        await s.write(detail: small);
        await s.write(detail: small);
        await s.write(detail: small);
        final listing = await env.listDir('.fah/trajectories/s1/requests');
        expect(listing.valueOrNull!.length, 3);
      },
    );

    test(
      'expired blobs (older than the TTL) are pruned on the next write',
      () async {
        final now = DateTime(2026, 1, 1);
        var current = now;
        final s = store(ttlDays: 30, clock: () => current);
        await s.write(detail: _detail());
        // Pin the first blob's mtime to the fake clock (the memory fs
        // stamps real wall-clock) so the age math is deterministic, age it
        // past the TTL, then write again: the sweep removes it.
        env.setMtime(
          '.fah/trajectories/s1/requests/1.json',
          now.millisecondsSinceEpoch,
        );
        current = now.add(const Duration(days: 31));
        final spill = await s.write(detail: _detail());
        expect(spill!.file, endsWith('2.json'));
        final names = (await env.listDir(
          '.fah/trajectories/s1/requests',
        )).valueOrNull!.map((f) => f.name).toList();
        expect(names, ['2.json']);
      },
    );
  });

  group('boot-time TTL sweep (gh-1745 review)', () {
    late MemoryExecutionEnv env;

    setUp(() => env = MemoryExecutionEnv(cwd: '/work'));

    TrajectoryRequestBlobStore store({
      String? Function()? sessionId,
      int maxBytes = trajectoryRequestBlobMaxBytes,
      int ttlDays = trajectoryRequestBlobTtlDays,
      DateTime Function()? clock,
    }) => TrajectoryRequestBlobStore(
      env: env,
      sessionId: sessionId ?? () => 's1',
      maxBytes: maxBytes,
      ttlDays: ttlDays,
      clock: clock,
    );

    Future<void> seedStale(String path, DateTime mtime) async {
      await env.writeFile(path, '{"detail":{}}');
      env.setMtime(path, mtime.millisecondsSinceEpoch);
    }

    test('sweepExpiredEverywhere prunes expired blobs in every session dir, '
        'including a dead session\'s newest', () async {
      final now = DateTime(2026, 1, 1);
      var current = now;
      final s = store(ttlDays: 30, clock: () => current);
      await s.write(detail: _detail());
      // A dead sibling session whose blobs aged past the TTL — rotation
      // can never reach them again (that session never writes).
      await seedStale(
        '.fah/trajectories/dead/requests/1.json',
        now.subtract(const Duration(days: 40)),
      );
      await seedStale(
        '.fah/trajectories/dead/requests/2.json',
        now.subtract(const Duration(days: 40)),
      );
      // A fresh blob in another live session stays (fresh relative to the
      // advanced clock, not the write wall-clock).
      await seedStale(
        '.fah/trajectories/live/requests/1.json',
        now.add(const Duration(days: 30)),
      );

      current = now.add(const Duration(days: 31));
      final deleted = await s.sweepExpiredEverywhere();

      expect(deleted, 2);
      expect(
        (await env.listDir(
          '.fah/trajectories/dead/requests',
        )).valueOrNull,
        isEmpty,
        reason: 'a dead session keeps NOTHING past the TTL — including its '
            'newest blob (no newest-kept grace on the boot sweep)',
      );
      expect(
        (await env.listDir(
          '.fah/trajectories/live/requests',
        )).valueOrNull!.single.name,
        '1.json',
      );
      // The sweeping session's own fresh blob survives too.
      expect(
        (await env.listDir(
          '.fah/trajectories/s1/requests',
        )).valueOrNull!.map((f) => f.name),
        ['1.json'],
      );
    });

    test('a missing trajectories root is a no-op (fresh workspace)', () async {
      expect(await store().sweepExpiredEverywhere(), 0);
    });

    test('the first write sweeps stale siblings (hosts need no extra '
        'wiring)', () async {
      final now = DateTime.now();
      await seedStale(
        '.fah/trajectories/dead/requests/1.json',
        now.subtract(const Duration(days: 40)),
      );

      final spill = await store(ttlDays: 30).write(detail: _detail());

      expect(spill, isNotNull);
      expect(
        (await env.listDir(
          '.fah/trajectories/dead/requests',
        )).valueOrNull,
        isEmpty,
      );
      // The sweep is once per store instance: a second write must not
      // re-list the root (the per-write sweep hour gate stays intact).
      final spill2 = await store(ttlDays: 30).write(detail: _detail());
      expect(spill2!.file, endsWith('2.json'));
    });
  });
}
