@TestOn('vm')
library;

/// gh-1589 (UT-1/UT-5): the session seal — after the run's terminal state
/// is recorded (`runHeadless` completes, REPL teardown), the session JSONL
/// is immutable FOR THIS PROCESS: every writer observes the closed state,
/// late writes are dropped with exactly ONE loud warning per writer class,
/// never appended, never thrown into an unhandled zone (I1). A sealed
/// session still resumes normally (I5/E5): a NEW Session instance over the
/// same file appends a fresh segment — the seal is per-run state in the
/// writer, not per-file-forever, and no session file format changes.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// The text of a user message (string or content-block content) — the test
/// twin of the harness's `messageText` helper.
String _textOf(Message message) {
  if (message is! UserMessage) return '';
  final content = message.content;
  if (content is String) return content;
  for (final block in content as List<ContentBlock>) {
    if (block is TextContent) return block.text;
  }
  return '';
}

void main() {
  late MemoryExecutionEnv env;
  late JsonlSessionRepo repo;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  });

  Future<List<SessionRecord>> recordsOnDisk() async {
    final meta = (await repo.list(cwd: '/work')).single;
    final reopened = await repo.open(meta);
    return reopened.getEntries();
  }

  group('UT-1: seal state machine', () {
    test(
      'a sealed session drops message appends with ONE warning per class',
      () async {
        final session = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        await session.appendMessage(UserMessage.text('before'));
        final warnings = <String>[];
        session.seal(onLateWrite: warnings.add);
        expect(session.isSealed, isTrue);

        // Two late writes of the SAME class: exactly one warning.
        await session.appendMessage(UserMessage.text('late 1'));
        await session.appendMessage(UserMessage.text('late 2'));
        expect(warnings, hasLength(1));
        expect(warnings.single, contains('message'));

        // The disk holds the pre-seal record only — nothing was appended.
        final texts = [
          for (final record in await recordsOnDisk())
            if (record is MessageRecord) _textOf(record.message),
        ];
        expect(texts, ['before']);
      },
    );

    test('each custom record type is its own writer class', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final warnings = <String>[];
      session.seal(onLateWrite: warnings.add);

      await session.appendCustomEntry(
        customType: 'shell_job_registry',
        data: const <Object>[],
      );
      await session.appendCustomEntry(
        customType: 'shell_job_registry',
        data: const <Object>[],
      );
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('shell_job_registry'));

      // A DIFFERENT type warns once more — one loud line per class.
      await session.appendCustomEntry(
        customType: 'obligations_ledger',
        data: const <Object>[],
      );
      expect(warnings, hasLength(2));
      expect(warnings.last, contains('obligations_ledger'));

      final customs = [
        for (final record in await recordsOnDisk())
          if (record is CustomRecord) record.customType,
      ];
      expect(customs, isEmpty);
    });

    test('a sealed append never throws and resolves to a stable value',
        () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      session.seal();
      // No sink wired: the default degrades to a silent drop, never a
      // throw into an unhandled zone.
      final id = await session.appendMessage(UserMessage.text('late'));
      expect(id, isNotNull);
      await session.appendCustomEntry(customType: 'x', data: 1);
    });

    test('sealing is idempotent — the first sink stays the sink', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final first = <String>[];
      final second = <String>[];
      session.seal(onLateWrite: first.add);
      session.seal(onLateWrite: second.add);
      await session.appendMessage(UserMessage.text('late'));
      expect(first, hasLength(1));
      expect(second, isEmpty);
    });
  });

  group('UT-5: resume after seal', () {
    test('a sealed session reopened by a new Session appends normally',
        () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('first run'));
      session.seal();

      // E5: the seal is per-run, not per-file-forever — a new process (a
      // resume, a wake loop) opens the SAME file unsealed and appends.
      final meta = (await repo.list(cwd: '/work')).single;
      final resumed = await repo.open(meta);
      expect(resumed.isSealed, isFalse);
      await resumed.appendMessage(UserMessage.text('resumed'));

      final texts = [
        for (final record in await recordsOnDisk())
          if (record is MessageRecord) _textOf(record.message),
      ];
      expect(texts, ['first run', 'resumed']);
    });

    test('the seal does not touch the session file bytes', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('data'));
      final meta = (await repo.list(cwd: '/work')).single;
      final before = (await env.readTextFile(meta.path)).valueOrNull;
      session.seal();
      final after = (await env.readTextFile(meta.path)).valueOrNull;
      expect(after, before, reason: 'no new session file format, no marker');
    });
  });
}
