import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  group('JsonlSessionRepo', () {
    test('create lays out files per pi scheme: root/encoded-cwd/ts_id.jsonl', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work/dir', id: 'sess-1'),
      );
      final metadata = await session.getMetadata();
      expect(metadata.id, 'sess-1');
      expect(metadata.path, matches(r'^/sessions/--work-dir--/.+_sess-1\.jsonl$'));
      expect((await fs.exists(metadata.path)).valueOrNull, isTrue);
    });

    test('create rejects nothing; ids default to unique generated values', () async {
      final a = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      final b = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      expect((await a.getMetadata()).id, isNot((await b.getMetadata()).id));
    });

    test('open re-loads an existing session with its entries', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      await session.appendMessage(UserMessage.text('persisted'));
      final metadata = await session.getMetadata();

      final reopened = await repo.open(metadata);
      final messages = await reopened.buildContextMessages();
      expect((messages.single as UserMessage).content, 'persisted');
    });

    test('open of a missing session throws not_found', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
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

    test('list returns sessions newest first, filtered by cwd', () async {
      final a = await repo.create(JsonlSessionCreateOptions(cwd: '/work', id: 'a'));
      final b = await repo.create(JsonlSessionCreateOptions(cwd: '/other', id: 'b'));
      final c = await repo.create(JsonlSessionCreateOptions(cwd: '/work', id: 'c'));

      final all = await repo.list();
      expect(
        all.map((m) => m.id),
        containsAll([(await a.getMetadata()).id, (await b.getMetadata()).id, (await c.getMetadata()).id]),
      );
      final createdAts = all.map((m) => m.createdAt).toList();
      final sorted = [...createdAts]..sort((x, y) => y.compareTo(x));
      expect(createdAts, sorted);

      final workOnly = await repo.list(cwd: '/work');
      expect(workOnly.map((m) => m.cwd).toSet(), {'/work'});
      expect(workOnly, hasLength(2));
    });

    test('list skips corrupt session files', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      final metadata = await session.getMetadata();
      await fs.writeFile(metadata.path, 'garbage\n');
      expect(await repo.list(), isEmpty);
    });

    test('delete removes the session file', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      final metadata = await session.getMetadata();
      await repo.delete(metadata);
      expect((await fs.exists(metadata.path)).valueOrNull, isFalse);
    });

    test('fork copies the full tree by default and records parent session', () async {
      final source = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
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
    });

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
  });
}
