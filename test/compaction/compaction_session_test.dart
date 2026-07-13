import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage _assistant(String text) {
  return AssistantMessage(
    content: [TextContent(text: text)],
    api: 'openai-completions',
    provider: 'openrouter',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

/// Fake summarizer: records prompts, replays scripted results.
class _FakeSummarizer {
  _FakeSummarizer(this.results);

  final List<SummarizationResult> results;
  final prompts = <String>[];

  Future<SummarizationResult> call(SummarizationRequest request) async {
    prompts.add(request.prompt);
    return results.removeAt(0);
  }
}

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  Future<Session> newSession() {
    return repo.create(JsonlSessionCreateOptions(cwd: '/work'));
  }

  /// Settings with a tiny keep-recent budget so a handful of messages
  /// triggers a cut.
  const settings = CompactionSettings(
    enabled: true,
    reserveTokens: 16384,
    keepRecentTokens: 150,
  );

  /// Appends four ~100-token messages: u1, a1, u2, a2.
  Future<Session> sessionWithHistory() async {
    final session = await newSession();
    await session.appendMessage(UserMessage.text('u1${'a' * 400}'));
    await session.appendMessage(_assistant('b' * 400));
    await session.appendMessage(UserMessage.text('u2${'a' * 400}'));
    await session.appendMessage(_assistant('b' * 400));
    return session;
  }

  group('compactSession (full pipeline through a Session)', () {
    test('appends a CompactionRecord and rebuilds context around it', () async {
      final session = await sessionWithHistory();
      final fake = _FakeSummarizer([
        SummarizationResult.success('THE SUMMARY'),
      ]);
      final manager = CompactionManager(
        summarize: fake.call,
        settings: settings,
      );

      final record = await manager.compactSession(session);

      expect(record, isNotNull);
      expect(record!.summary, startsWith('THE SUMMARY'));
      expect(record.tokensBefore, greaterThan(0));
      // Budget 150 -> cut at u2; u1/a1 are summarized.
      final u2Entry = await session.getEntry(record.firstKeptEntryId);
      expect(u2Entry, isA<MessageRecord>());
      expect((u2Entry! as MessageRecord).message.role, 'user');
      expect(
        ((u2Entry as MessageRecord).message as UserMessage).content,
        startsWith('u2'),
      );

      // The compaction prompt contains the summarized region only.
      expect(fake.prompts.single, contains('u1'));
      expect(fake.prompts.single, isNot(contains('u2aaaa')));

      // Context projection: summary user message, then the kept messages.
      final messages = await session.buildContextMessages();
      expect(messages, hasLength(3));
      final summaryMessage = messages.first as UserMessage;
      expect(summaryMessage.content, startsWith(compactionSummaryPrefix));
      expect(summaryMessage.content, contains('THE SUMMARY'));
      expect(messages[1].role, 'user');
      expect(messages[2].role, 'assistant');

      // The record survives a reload from disk.
      final reopened = await repo.open(await session.getMetadata());
      final branch = await reopened.getBranch();
      expect(branch.whereType<CompactionRecord>(), hasLength(1));
    });

    test(
      'summarization failure is failure-safe: history fully preserved',
      () async {
        final session = await sessionWithHistory();
        final before = await session.getBranch();
        final fake = _FakeSummarizer([
          SummarizationResult.failure('provider exploded'),
        ]);
        final manager = CompactionManager(
          summarize: fake.call,
          settings: settings,
        );

        expect(
          () => manager.compactSession(session),
          throwsA(
            isA<CompactionException>().having(
              (e) => e.code,
              'code',
              CompactionErrorCode.summarizationFailed,
            ),
          ),
        );

        // No compaction record appended; the branch is byte-identical.
        final after = await session.getBranch();
        expect(after.map((e) => e.id), before.map((e) => e.id));
        expect(after.whereType<CompactionRecord>(), isEmpty);
        final messages = await session.buildContextMessages();
        expect(messages, hasLength(4));
      },
    );

    test('empty session: nothing to compact', () async {
      final session = await newSession();
      final manager = CompactionManager(
        summarize: (_) async => SummarizationResult.success('x'),
        settings: settings,
      );
      expect(await manager.compactSession(session), isNull);
    });

    test('second compaction updates the previous summary', () async {
      final session = await sessionWithHistory();
      final fake = _FakeSummarizer([
        SummarizationResult.success('FIRST'),
        SummarizationResult.success('SECOND'),
      ]);
      final manager = CompactionManager(
        summarize: fake.call,
        settings: settings,
      );

      final first = await manager.compactSession(session);
      expect(first, isNotNull);

      // Grow history past the budget again.
      await session.appendMessage(UserMessage.text('u3${'a' * 400}'));
      await session.appendMessage(_assistant('b' * 400));

      final second = await manager.compactSession(session);
      expect(second, isNotNull);
      expect(second!.summary, startsWith('SECOND'));

      // The second prompt updates the first summary (pi iterative mode).
      expect(fake.prompts[1], contains('<previous-summary>'));
      expect(fake.prompts[1], contains('FIRST'));

      // Only the latest compaction projects into the context.
      final messages = await session.buildContextMessages();
      expect(messages.first, isA<UserMessage>());
      expect((messages.first as UserMessage).content, contains('SECOND'));
      expect(
        messages.where((m) {
          return m is UserMessage &&
              m.content is String &&
              (m.content as String).contains('FIRST');
        }),
        isEmpty,
      );
    });

    test('estimates tokens from provider usage when available', () async {
      final session = await newSession();
      await session.appendMessage(UserMessage.text('hi'));
      await session.appendMessage(
        AssistantMessage(
          content: [const TextContent(text: 'hello')],
          api: 'openai-completions',
          provider: 'openrouter',
          model: 'm1',
          usage: const Usage(
            input: 42000,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 42000,
            cost: UsageCost(),
          ),
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
      );
      await session.appendMessage(UserMessage.text('u${'a' * 400}'));
      await session.appendMessage(_assistant('b' * 400));
      final fake = _FakeSummarizer([SummarizationResult.success('S')]);
      final manager = CompactionManager(
        summarize: fake.call,
        settings: settings,
      );

      final record = await manager.compactSession(session);
      // tokensBefore = 42000 (usage) + trailing heuristic (101 + 100).
      expect(record!.tokensBefore, 42201);
    });
  });

  group('shouldCompact against a session', () {
    test('composes estimateContextTokens with the model window', () async {
      final session = await sessionWithHistory();
      final tokens = estimateContextTokens(
        await session.buildContextMessages(),
      ).tokens;
      // Each message is ~100 tokens (user messages have a 2-char prefix).
      expect(tokens, 402);
      expect(shouldCompact(tokens, 42000, defaultCompactionSettings), isFalse);
      // 17000 - 16384 = 616; 402 stays below the reserve.
      expect(shouldCompact(tokens, 17000, defaultCompactionSettings), isFalse);
      // 16500 - 16384 = 116; 402 exceeds it.
      expect(shouldCompact(tokens, 16500, defaultCompactionSettings), isTrue);
    });
  });
}
