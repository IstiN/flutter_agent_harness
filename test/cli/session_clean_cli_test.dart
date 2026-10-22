/// gh-1746 — the headless `fa session clean [--dry-run]` command (AC6):
/// a dry run prints the exact plan and deletes nothing; apply performs
/// exactly that plan. MemoryExecutionEnv + injected clock, no real fs.
@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/session_clean_command.dart';
import 'package:test/test.dart';

DateTime _clockNow = DateTime(2026, 1, 10, 12);

DateTime _clock() => _clockNow;

DateTime daysAgo(int age) => _clockNow.subtract(Duration(days: age));

/// Output sink shaped like a [CliIO] tear-off pair.
final class _CleanIo {
  final buffer = StringBuffer();
  void write(String text) => buffer.write(text);
  void writeln(String text) => buffer.writeln(text);
}

void main() {
  late MemoryExecutionEnv env;
  late JsonlSessionRepo repo;
  late FileSessionPresenceStore presence;

  setUp(() {
    _clockNow = DateTime(2026, 1, 10, 12);
    env = MemoryExecutionEnv(cwd: '/work');
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    // The fail-closed posture (gh-1746 review): a sweep without a
    // presence store aborts — wire one, exactly like production
    // (bin/fah_runapp.dart) always does.
    presence = FileSessionPresenceStore(
      env: env,
      root: '/sessions',
      now: _clock,
    );
  });

  Future<String> seedSession({
    String? name,
    DateTime? createdAt,
    DateTime? lastUsed,
    int sizeBytes = 0,
  }) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    if (sizeBytes > 0) {
      await session.appendMessage(UserMessage.text('x' * sizeBytes));
    }
    if (name != null) await session.appendSessionName(name);
    final metadata = await session.getMetadata();
    if (createdAt != null) {
      final raw = (await env.readTextFile(metadata.path)).valueOrNull!;
      await env.writeFile(
        metadata.path,
        raw.replaceFirst(
          RegExp(r'"timestamp":"[^"]+"'),
          '"timestamp":"${createdAt.toIso8601String()}"',
        ),
      );
    }
    env.setMtime(
      metadata.path,
      (lastUsed ?? createdAt ?? _clockNow).millisecondsSinceEpoch,
    );
    return metadata.id;
  }

  group('runSessionCleanCliCommand (fa session clean)', () {
    test('dry run prints the plan and deletes nothing (AC6)', () async {
      final doomed = await seedSession(
        createdAt: daysAgo(90),
        lastUsed: daysAgo(60),
        sizeBytes: 100,
      );
      final io = _CleanIo();
      final code = await runSessionCleanCliCommand(
        write: io.write,
        writeln: io.writeln,
        env: env,
        sessionRoot: '/sessions',
        presenceStore: presence,
        now: _clock,
        dryRun: true,
        retention: const SessionRetentionConfig(maxTotalBytes: 1),
      );
      expect(code, 0);
      expect(io.buffer.toString(), contains('would delete'));
      expect(io.buffer.toString(), contains(doomed));
      expect(io.buffer.toString(), contains('dry run'));
      // Nothing was deleted.
      expect((await repo.list()).map((m) => m.id), contains(doomed));
    });

    test('apply deletes exactly the planned units and reports (AC6)', () async {
      final doomed = await seedSession(
        createdAt: daysAgo(90),
        lastUsed: daysAgo(60),
        sizeBytes: 100,
      );
      final keeper = await seedSession(
        name: 'keep-named',
        createdAt: daysAgo(90),
        lastUsed: daysAgo(1),
      );
      final io = _CleanIo();
      final code = await runSessionCleanCliCommand(
        write: io.write,
        writeln: io.writeln,
        env: env,
        sessionRoot: '/sessions',
        presenceStore: presence,
        now: _clock,
        dryRun: false,
        retention: const SessionRetentionConfig(maxTotalBytes: 1),
      );
      expect(code, 0);
      final out = io.buffer.toString();
      expect(out, contains('deleted'));
      expect(out, contains(doomed));
      // The named session survives (keepNamed default) and the doomed
      // transcript is gone.
      expect((await repo.list()).map((m) => m.id), contains(keeper));
      expect((await repo.list()).map((m) => m.id), isNot(contains(doomed)));
    });

    test(
      'no cap configured: prints the hint, exits 0, deletes nothing',
      () async {
        await seedSession(createdAt: daysAgo(90), lastUsed: daysAgo(60));
        final io = _CleanIo();
        final code = await runSessionCleanCliCommand(
          write: io.write,
          writeln: io.writeln,
          env: env,
          sessionRoot: '/sessions',
          presenceStore: presence,
          now: _clock,
          retention: const SessionRetentionConfig(),
        );
        expect(code, 0);
        expect(io.buffer.toString(), contains('sessions.retention'));
        expect((await repo.list()), isNotEmpty);
      },
    );
  });
}
