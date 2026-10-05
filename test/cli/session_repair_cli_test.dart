import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/session_repair_command.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:test/test.dart';

/// Output sink for the repair command (a CliIO tear-off pair shape).
final class _RepairIo {
  final buffer = StringBuffer();
  void write(String text) => buffer.write(text);
  void writeln(String text) => buffer.writeln(text);
}

void main() {
  late MemoryFileSystem fs;

  setUp(() {
    fs = MemoryFileSystem(cwd: '/work');
  });

  Future<void> seedSession(String id) async {
    final repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
    final session = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', id: id),
    );
    for (var i = 0; i < 5; i++) {
      await session.appendCustomEntry(
        customType: 'model_request_summary',
        data: {'n': i, 'pad': 'p' * 5000},
      );
    }
    await session.appendMessage(UserMessage.text('keep me'));
  }

  group('runSessionRepairCliCommand (headless fa session repair)', () {
    test('repairs by session id and reports the ledger surgery', () async {
      await seedSession('repair-me');
      final io = _RepairIo();
      final code = await runSessionRepairCliCommand(
        write: io.write,
        writeln: io.writeln,
        env: fs,
        sessionRoot: '/sessions',
        sessionId: 'repair-me',
      );
      expect(code, 0);
      expect(io.buffer.toString(), contains('repaired'));
      expect(io.buffer.toString(), contains('model_request_summary×5'));
      expect(io.buffer.toString(), contains('.bak'));
      // The session still opens and the conversation survives.
      final repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
      final metadata = await resolveRepairableSession(repo, 'repair-me');
      expect(metadata, isNotNull);
      final content =
          (await fs.readTextFile(metadata!.path)).getOrThrow();
      final lines = content.trim().split('\n');
      expect(
        lines
            .map((l) => (jsonDecode(l) as Map)['type'])
            .where((t) => t == 'custom'),
        isEmpty,
        reason: 'the ledger records are gone',
      );
      expect((await fs.exists('${metadata.path}.bak')).getOrThrow(), isTrue);
    });

    test('--dry-run counts without writing', () async {
      await seedSession('dry-run-me');
      final io = _RepairIo();
      final code = await runSessionRepairCliCommand(
        write: io.write,
        writeln: io.writeln,
        env: fs,
        sessionRoot: '/sessions',
        sessionId: 'dry-run-me',
        dryRun: true,
      );
      expect(code, 0);
      expect(io.buffer.toString(), contains('would repair'));
      expect(io.buffer.toString(), contains('dry run: nothing written'));
      final repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
      final metadata = await resolveRepairableSession(repo, 'dry-run-me');
      final content =
          (await fs.readTextFile(metadata!.path)).getOrThrow();
      expect(content, contains('model_request_summary'));
      expect((await fs.exists('${metadata.path}.bak')).getOrThrow(), isFalse);
    });

    test('a live session given by direct path is refused too', () async {
      await seedSession('live-by-path');
      final repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
      final metadata = await resolveRepairableSession(repo, 'live-by-path');
      final io = _RepairIo();
      final code = await runSessionRepairCliCommand(
        write: io.write,
        writeln: io.writeln,
        env: fs,
        sessionRoot: '/sessions',
        sessionId: metadata!.path,
        presenceStore: _LivePresence('live-by-path'),
      );
      expect(code, 1);
      expect(io.buffer.toString(), contains('is live'));
      // The file is untouched — nothing was rewritten under the writer.
      final content =
          (await fs.readTextFile(metadata.path)).getOrThrow();
      expect(content, contains('model_request_summary'));
    });

    test('repairing a non-live session by direct path works', () async {
      await seedSession('path-target');
      final repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
      final metadata = await resolveRepairableSession(repo, 'path-target');
      final io = _RepairIo();
      final code = await runSessionRepairCliCommand(
        write: io.write,
        writeln: io.writeln,
        env: fs,
        sessionRoot: '/sessions',
        sessionId: metadata!.path,
      );
      expect(code, 0);
      expect(io.buffer.toString(), contains('repaired'));
      expect(
        (await fs.exists('${metadata.path}.bak')).getOrThrow(),
        isTrue,
      );
    });

    test('a live session is refused', () async {
      await seedSession('live-one');
      final io = _RepairIo();
      final code = await runSessionRepairCliCommand(
        write: io.write,
        writeln: io.writeln,
        env: fs,
        sessionRoot: '/sessions',
        sessionId: 'live-one',
        presenceStore: _LivePresence('live-one'),
      );
      expect(code, 1);
      expect(io.buffer.toString(), contains('is live'));
    });

    test('an unknown session fails cleanly', () async {
      final io = _RepairIo();
      final code = await runSessionRepairCliCommand(
        write: io.write,
        writeln: io.writeln,
        env: fs,
        sessionRoot: '/sessions',
        sessionId: 'nope',
      );
      expect(code, 1);
      expect(io.buffer.toString(), contains('not found'));
    });
  });
}

/// A presence store reporting one live session.
final class _LivePresence implements SessionPresenceStore {
  _LivePresence(this.id);

  final String id;

  @override
  Future<void> register(String sessionId, {int? pid, String? host}) async {}

  @override
  Future<void> touch(String sessionId) async {}

  @override
  Future<void> unregister(String sessionId) async {}

  @override
  Future<Map<String, SessionPresence>> list() async => {
    id: SessionPresence(
      sessionId: id,
      pid: 4242,
      host: 'test',
      startedAt: DateTime.now().toIso8601String(),
      touchedAt: DateTime.now().toIso8601String(),
    ),
  };
}
