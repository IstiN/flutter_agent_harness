import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  Future<Session> newSession({String cwd = '/work'}) {
    return repo.create(JsonlSessionCreateOptions(cwd: cwd));
  }

  AssistantMessage assistant(String text) => AssistantMessage(
    content: [TextContent(text: text)],
    api: 'openai-completions',
    provider: 'openrouter',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );

  group('Session append and navigation', () {
    test('appendMessage chains parent ids along the leaf', () async {
      final session = await newSession();
      final id1 = await session.appendMessage(UserMessage.text('one'));
      final id2 = await session.appendMessage(assistant('two'));
      final e1 = await session.getEntry(id1);
      final e2 = await session.getEntry(id2);
      expect(e1?.parentId, isNull);
      expect(e2?.parentId, id1);
      expect(await session.getLeafId(), id2);
    });

    test(
      'branching: two children from one parent have independent paths',
      () async {
        final session = await newSession();
        final root = await session.appendMessage(UserMessage.text('root'));
        final branchA = await session.appendMessage(UserMessage.text('A'));
        await session.moveTo(root);
        final branchB = await session.appendMessage(UserMessage.text('B'));

        final a = await session.getEntry(branchA);
        final b = await session.getEntry(branchB);
        expect(a?.parentId, root);
        expect(b?.parentId, root);

        final pathA = await session.getBranch(fromId: branchA);
        final pathB = await session.getBranch(fromId: branchB);
        expect(pathA.map((e) => e.id), [root, branchA]);
        expect(pathB.map((e) => e.id), [root, branchB]);
        expect(await session.getLeafId(), branchB);
      },
    );

    test('getChildren groups records by parentId', () async {
      final session = await newSession();
      final root = await session.appendMessage(UserMessage.text('root'));
      final a = await session.appendMessage(UserMessage.text('A'));
      await session.moveTo(root);
      final b = await session.appendMessage(UserMessage.text('B'));

      final children = await session.getChildren(root);
      expect(children.map((e) => e.id), containsAll([a, b]));
      expect(await session.getChildren('ghost'), isEmpty);
      final roots = await session.getChildren(null);
      expect(roots.map((e) => e.id), contains(root));
    });

    test('moveTo to unknown entry throws not_found', () async {
      final session = await newSession();
      expect(
        () => session.moveTo('ghost'),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.notFound,
          ),
        ),
      );
    });

    test('moveTo with summary appends a branch_summary record', () async {
      final session = await newSession();
      final root = await session.appendMessage(UserMessage.text('root'));
      await session.appendMessage(UserMessage.text('detour'));
      final summaryId = await session.moveTo(root, summary: 'went back');
      final record = await session.getEntry(summaryId!);
      expect(record, isA<BranchSummaryRecord>());
      final summary = record! as BranchSummaryRecord;
      expect(summary.fromId, root);
      expect(summary.summary, 'went back');
      expect(summary.parentId, root);
    });

    test('moveTo(null) jumps to the tree root', () async {
      final session = await newSession();
      await session.appendMessage(UserMessage.text('one'));
      await session.moveTo(null);
      expect(await session.getLeafId(), isNull);
      final fresh = await session.appendMessage(UserMessage.text('new root'));
      expect((await session.getEntry(fresh))?.parentId, isNull);
    });

    test('labels validate the target and support removal', () async {
      final session = await newSession();
      final id = await session.appendMessage(UserMessage.text('x'));
      await session.appendLabel(id, 'marked');
      expect(await session.getLabel(id), 'marked');
      await session.appendLabel(id, null);
      expect(await session.getLabel(id), isNull);
      expect(
        () => session.appendLabel('ghost', 'x'),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.notFound,
          ),
        ),
      );
    });

    test('session name is sanitized and the last one wins', () async {
      final session = await newSession();
      expect(await session.getSessionName(), isNull);
      await session.appendSessionName('first');
      await session.appendSessionName('second\nwith newlines');
      expect(await session.getSessionName(), 'second with newlines');
    });
  });

  group('Session context rebuild', () {
    test('buildContextMessages walks leaf to root, oldest first', () async {
      final session = await newSession();
      await session.appendMessage(UserMessage.text('one'));
      await session.appendMessage(assistant('two'));
      await session.appendMessage(UserMessage.text('three'));
      final messages = await session.buildContextMessages();
      expect(messages.map((m) => m.role), ['user', 'assistant', 'user']);
      expect((messages.first as UserMessage).content, 'one');
    });

    test('context follows the active branch after moveTo', () async {
      final session = await newSession();
      final root = await session.appendMessage(UserMessage.text('root'));
      await session.appendMessage(UserMessage.text('A'));
      await session.moveTo(root);
      await session.appendMessage(UserMessage.text('B'));
      final messages = await session.buildContextMessages();
      expect(messages.map((m) => (m as UserMessage).content), ['root', 'B']);
    });

    test(
      'compaction record replaces everything before firstKeptEntryId',
      () async {
        final session = await newSession();
        await session.appendMessage(UserMessage.text('old 1'));
        final kept = await session.appendMessage(UserMessage.text('kept 1'));
        await session.appendMessage(UserMessage.text('kept 2'));
        await session.appendCompaction(
          summary: 'summary of old',
          firstKeptEntryId: kept,
          tokensBefore: 9000,
        );
        await session.appendMessage(UserMessage.text('after'));

        final messages = await session.buildContextMessages();
        expect(messages, hasLength(4));
        final first = (messages.first as UserMessage).content as String;
        expect(first, startsWith(compactionSummaryPrefix));
        expect(first, contains('summary of old'));
        expect(messages.skip(1).map((m) => (m as UserMessage).content), [
          'kept 1',
          'kept 2',
          'after',
        ]);
      },
    );

    test(
      'branch_summary records project into context as user messages',
      () async {
        final session = await newSession();
        final root = await session.appendMessage(UserMessage.text('root'));
        await session.appendMessage(UserMessage.text('detour'));
        await session.moveTo(root, summary: 'the detour did X');
        final messages = await session.buildContextMessages();
        final last = (messages.last as UserMessage).content as String;
        expect(last, startsWith(branchSummaryPrefix));
        expect(last, contains('the detour did X'));
      },
    );

    test(
      'custom_message projects into context; custom records do not',
      () async {
        final session = await newSession();
        await session.appendCustomMessageEntry(
          customType: 'note',
          content: 'a displayed note',
          display: true,
        );
        await session.appendCustomEntry(
          customType: 'checkpoint',
          data: {'n': 1},
        );
        final messages = await session.buildContextMessages();
        expect(messages, hasLength(1));
        expect((messages.single as UserMessage).content, 'a displayed note');
      },
    );

    test(
      'buildContext derives model, thinking level, and active tools',
      () async {
        final session = await newSession();
        await session.appendModelChange(
          provider: 'anthropic',
          modelId: 'claude',
        );
        await session.appendThinkingLevelChange('high');
        await session.appendActiveToolsChange(const ['read', 'write']);
        await session.appendMessage(UserMessage.text('hi'));
        await session.appendMessage(assistant('hello'));

        final context = await session.buildContext();
        expect(context.thinkingLevel, 'high');
        expect(context.model?.provider, 'openrouter'); // assistant message wins
        expect(context.model?.modelId, 'm1');
        expect(context.activeToolNames, ['read', 'write']);
        expect(context.messages, hasLength(2));
      },
    );

    test('buildContext defaults when nothing was recorded', () async {
      final session = await newSession();
      final context = await session.buildContext();
      expect(context.messages, isEmpty);
      expect(context.thinkingLevel, 'off');
      expect(context.model, isNull);
      expect(context.activeToolNames, isNull);
    });
  });
}
