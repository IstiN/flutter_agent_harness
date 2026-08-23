import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  group('encodeSessionCwd / decodeSessionCwd', () {
    test('decodes a slug back to its absolute path', () {
      expect(
        decodeSessionCwd('--Users-Uladzimir_Klyshevich-git-dm.ai--'),
        '/Users/Uladzimir_Klyshevich/git/dm.ai',
      );
    });

    test('round-trips typical absolute paths', () {
      expect(decodeSessionCwd(encodeSessionCwd('/foo/bar')), '/foo/bar');
      expect(
        decodeSessionCwd(
          encodeSessionCwd('/Users/Uladzimir_Klyshevich/git/dm.ai'),
        ),
        '/Users/Uladzimir_Klyshevich/git/dm.ai',
      );
      expect(decodeSessionCwd(encodeSessionCwd('/single')), '/single');
    });

    test('ignores trailing slashes when encoding', () {
      expect(encodeSessionCwd('/foo/bar/'), encodeSessionCwd('/foo/bar'));
      expect(encodeSessionCwd('/foo/bar//'), encodeSessionCwd('/foo/bar'));
    });

    test('returns null for bad or empty slugs', () {
      expect(decodeSessionCwd('Users-Uladzimir_Klyshevich-git-dm.ai'), isNull);
      expect(decodeSessionCwd('--Users'), isNull);
      expect(decodeSessionCwd('Users--'), isNull);
      expect(decodeSessionCwd('--'), isNull);
      expect(decodeSessionCwd(''), isNull);
      expect(decodeSessionCwd('---foo---'), isNull);
    });
  });

  group('JsonlSessionRepo', () {
    test('create lays out files under an encoded cwd directory', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work/dir', id: 'sess-1'),
      );
      final metadata = await session.getMetadata();
      expect(metadata.id, 'sess-1');
      expect(metadata.cwd, '/work/dir');
      expect(
        metadata.path,
        matches(r'^/sessions/--work-dir--/.+_sess-1\.jsonl$'),
      );
      expect((await fs.exists(metadata.path)).valueOrNull, isTrue);
    });

    test(
      'create rejects nothing; ids default to unique generated values',
      () async {
        final a = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
        final b = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
        expect((await a.getMetadata()).id, isNot((await b.getMetadata()).id));
      },
    );

    test('open re-loads an existing session with its entries', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('persisted'));
      final metadata = await session.getMetadata();

      final reopened = await repo.open(metadata);
      final messages = await reopened.buildContextMessages();
      expect((messages.single as UserMessage).content, 'persisted');
    });

    test('open of a missing session throws not_found', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final metadata = await session.getMetadata();
      await fs.remove(metadata.path);
      expect(
        () => repo.open(metadata),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.notFound,
          ),
        ),
      );
    });

    test(
      'list returns sessions most recently updated first, filtered by cwd',
      () async {
        final a = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work', id: 'a'),
        );
        final b = await repo.create(
          JsonlSessionCreateOptions(cwd: '/other', id: 'b'),
        );
        final c = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work', id: 'c'),
        );

        final all = await repo.list();
        expect(
          all.map((m) => m.id),
          containsAll([
            (await a.getMetadata()).id,
            (await b.getMetadata()).id,
            (await c.getMetadata()).id,
          ]),
        );
        final activityTimes = all
            .map((m) => m.lastUpdatedAt ?? m.createdAt)
            .toList();
        final sorted = [...activityTimes]..sort((x, y) => y.compareTo(x));
        expect(activityTimes, sorted);

        final workOnly = await repo.list(cwd: '/work');
        expect(workOnly.map((m) => m.cwd).toSet(), {'/work'});
        expect(workOnly, hasLength(2));
      },
    );

    test('list skips corrupt session files', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final metadata = await session.getMetadata();
      await fs.writeFile(metadata.path, 'garbage\n');
      expect(await repo.list(), isEmpty);
    });

    test('delete removes the session file', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final metadata = await session.getMetadata();
      await repo.delete(metadata);
      expect((await fs.exists(metadata.path)).valueOrNull, isFalse);
    });

    test(
      'fork copies the full tree by default and records parent session',
      () async {
        final source = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        await source.appendMessage(UserMessage.text('one'));
        await source.appendMessage(UserMessage.text('two'));
        final sourceMeta = await source.getMetadata();

        final fork = await repo.fork(sourceMeta, cwd: '/work');
        final forkMeta = await fork.getMetadata();
        expect(forkMeta.parentSessionPath, sourceMeta.path);
        expect(forkMeta.id, isNot(sourceMeta.id));
        final messages = await fork.buildContextMessages();
        expect(messages.map((m) => (m as UserMessage).content), ['one', 'two']);

        // Fork is independent: appending to it does not touch the source.
        await fork.appendMessage(UserMessage.text('fork only'));
        expect(await source.buildContextMessages(), hasLength(2));
      },
    );

    test('fork at an entry truncates to that prefix', () async {
      final source = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      final one = await source.appendMessage(UserMessage.text('one'));
      await source.appendMessage(UserMessage.text('two'));

      final fork = await repo.fork(
        await source.getMetadata(),
        cwd: '/work',
        entryId: one,
        position: ForkPosition.at,
      );
      final messages = await fork.buildContextMessages();
      expect(messages.map((m) => (m as UserMessage).content), ['one']);
    });

    test('fork before a user message drops that message', () async {
      final source = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      final one = await source.appendMessage(UserMessage.text('one'));
      final two = await source.appendMessage(UserMessage.text('two'));

      final fork = await repo.fork(
        await source.getMetadata(),
        cwd: '/work',
        entryId: two,
      );
      final messages = await fork.buildContextMessages();
      expect(messages.map((m) => (m as UserMessage).content), ['one']);
      expect(one, isNotNull);
    });

    test('fork before a non-user message is rejected', () async {
      final source = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      await source.appendMessage(UserMessage.text('one'));
      final assistant = await source.appendMessage(
        AssistantMessage(
          content: const [TextContent(text: 'hi')],
          api: 'openai-completions',
          provider: 'p',
          model: 'm',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
      );
      final meta = await source.getMetadata();
      expect(
        () => repo.fork(meta, cwd: '/work', entryId: assistant),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.invalidForkTarget,
          ),
        ),
      );
    });

    test('fork of an unknown entry is rejected', () async {
      final source = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      final meta = await source.getMetadata();
      expect(
        () => repo.fork(meta, cwd: '/work', entryId: 'ghost'),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.invalidForkTarget,
          ),
        ),
      );
    });

    test(
      'cleanupEmptySessions removes header-only .jsonl files and keeps the rest',
      () async {
        final envFs = MemoryFileSystem();
        final cleanRepo = JsonlSessionRepo(
          fs: envFs,
          sessionsRoot: '/sessions',
        );
        // Empty session: header record only.
        final empty = await cleanRepo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        final emptyPath = (await empty.getMetadata()).path;
        // Real session: header + at least one entry.
        final real = await cleanRepo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        final realPath = (await real.getMetadata()).path;
        await real.appendMessage(UserMessage.text('hello'));

        final removed = await cleanRepo.cleanupEmptySessions();
        expect(removed, 1);
        expect((await envFs.exists(emptyPath)).valueOrNull, isFalse);
        expect((await envFs.exists(realPath)).valueOrNull, isTrue);
      },
    );

    test(
      'cleanupEmptySessions returns 0 and removes nothing when everything has '
      'transcript',
      () async {
        final envFs = MemoryFileSystem();
        final cleanRepo = JsonlSessionRepo(
          fs: envFs,
          sessionsRoot: '/sessions',
        );
        final s = await cleanRepo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        await s.appendMessage(UserMessage.text('one'));
        await s.appendMessage(UserMessage.text('two'));
        final removed = await cleanRepo.cleanupEmptySessions();
        expect(removed, 0);
        expect(
          (await envFs.exists((await s.getMetadata()).path)).valueOrNull,
          isTrue,
        );
      },
    );
  });
}
