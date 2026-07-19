import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage _assistant(String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

AssistantMessage _toolCalls(List<ToolCall> calls) => AssistantMessage(
  content: calls,
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.toolUse,
  timestamp: DateTime.utc(2026),
);

ToolResultMessage _toolResult(String callId, String name, String text) {
  return ToolResultMessage(
    toolCallId: callId,
    toolName: name,
    content: [TextContent(text: text)],
    isError: false,
    timestamp: DateTime.utc(2026),
  );
}

/// A [SummarizeFn] returning a fixed summary and recording its prompts.
class _FakeSummarizer {
  _FakeSummarizer(this.response);

  final String response;
  final prompts = <String>[];

  Future<SummarizationResult> call(SummarizationRequest request) async {
    prompts.add(request.prompt);
    return SummarizationResult.success(response);
  }
}

void main() {
  late JsonlSessionRepo repo;

  setUp(() {
    repo = JsonlSessionRepo(fs: MemoryFileSystem(), sessionsRoot: '/sessions');
  });

  Future<Session> newSession() {
    return repo.create(JsonlSessionCreateOptions(cwd: '/work'));
  }

  group('collectEntriesForBranchSummary', () {
    test(
      'returns entries from the old leaf back to the common ancestor',
      () async {
        final session = await newSession();
        final root = await session.appendMessage(UserMessage.text('root'));
        final a1 = await session.appendMessage(UserMessage.text('a1'));
        final a2 = await session.appendMessage(UserMessage.text('a2'));
        await session.moveTo(root);
        final b1 = await session.appendMessage(UserMessage.text('b1'));

        final collected = await collectEntriesForBranchSummary(
          session,
          a2, // old leaf
          b1,
        );
        expect(collected.commonAncestorId, root);
        expect(collected.entries.map((e) => e.id), [a1, a2]);
      },
    );

    test('returns nothing when there is no old position', () async {
      final session = await newSession();
      final root = await session.appendMessage(UserMessage.text('root'));
      final collected = await collectEntriesForBranchSummary(
        session,
        null,
        root,
      );
      expect(collected.entries, isEmpty);
      expect(collected.commonAncestorId, isNull);
    });
  });

  group('prepareBranchEntries', () {
    test('walks newest-to-oldest within the token budget', () async {
      final session = await newSession();
      await session.appendMessage(UserMessage.text('one'));
      final two = await session.appendMessage(UserMessage.text('two'));
      final three = await session.appendMessage(UserMessage.text('three'));
      final entries = [
        (await session.getEntry(two))!,
        (await session.getEntry(three))!,
      ];

      final unbudgeted = prepareBranchEntries(entries);
      expect(unbudgeted.messages, hasLength(2));

      // A budget for exactly one message keeps only the newest entry.
      final oneMessageTokens = estimateTokens(UserMessage.text('three'));
      final budgeted = prepareBranchEntries(
        entries,
        tokenBudget: oneMessageTokens,
      );
      expect(budgeted.messages, hasLength(1));
      expect((budgeted.messages.single as UserMessage).content, 'three');
    });

    test('accumulates file ops from nested branch summary details', () async {
      final session = await newSession();
      final nested = await session.appendCustomEntry(
        customType: 'marker',
        data: const {},
      );
      await session.getStorage().appendEntry(
        BranchSummaryRecord(
          id: await session.getStorage().createEntryId(),
          parentId: nested,
          timestamp: DateTime.utc(2026),
          fromId: 'x',
          summary: 'nested summary',
          details: const {
            'readFiles': ['a.dart'],
            'modifiedFiles': ['b.dart'],
          },
        ),
      );
      final entries = await session.getEntries();
      final preparation = prepareBranchEntries(entries);
      final lists = computeFileLists(preparation.fileOps);
      expect(lists.readFiles, ['a.dart']);
      expect(lists.modifiedFiles, ['b.dart']);
    });
  });

  group('generateBranchSummary', () {
    test('summarizes entries with preamble and file-operation tags', () async {
      final session = await newSession();
      await session.appendMessage(UserMessage.text('investigate caching'));
      await session.appendMessage(
        _toolCalls([
          const ToolCall(
            id: 'c1',
            name: 'read',
            arguments: {'path': 'lib/cache.dart'},
          ),
          const ToolCall(
            id: 'c2',
            name: 'edit',
            arguments: {'path': 'lib/cache.dart'},
          ),
        ]),
      );
      await session.appendMessage(_toolResult('c1', 'read', 'cache code'));
      await session.appendMessage(_toolResult('c2', 'edit', 'edited'));
      final entries = await session.getEntries();

      final summarizer = _FakeSummarizer('## Goal\n\nFix the cache.');
      final result = await generateBranchSummary(
        entries,
        summarize: summarizer.call,
      );

      expect(result.error, isNull);
      expect(result.aborted, isFalse);
      // Preamble from the Markdown prompt, then the LLM text.
      expect(
        result.summary,
        startsWith(
          'The user explored a different conversation branch before '
          'returning here.\nSummary of that exploration:\n',
        ),
      );
      expect(result.summary, contains('## Goal\n\nFix the cache.'));
      // File operations appended as metadata tags.
      expect(result.summary, contains('<modified-files>'));
      expect(result.summary, contains('lib/cache.dart'));
      expect(result.readFiles, isEmpty); // read file was also modified
      expect(result.modifiedFiles, ['lib/cache.dart']);

      // The summarizer saw the serialized conversation and the fixed
      // branch-summary instructions.
      final prompt = summarizer.prompts.single;
      expect(prompt, contains('<conversation>'));
      expect(prompt, contains('[User]: investigate caching'));
      expect(prompt, contains('structured summary of the conversation branch'));
    });

    test('returns "No content to summarize" for empty entries', () async {
      final summarizer = _FakeSummarizer('unused');
      final result = await generateBranchSummary(
        const [],
        summarize: summarizer.call,
      );
      expect(result.summary, 'No content to summarize');
      expect(summarizer.prompts, isEmpty);
    });

    test('surfaces summarization failure without throwing', () async {
      final session = await newSession();
      await session.appendMessage(UserMessage.text('work'));
      final entries = await session.getEntries();

      final result = await generateBranchSummary(
        entries,
        summarize: (request) async =>
            SummarizationResult.failure('provider down'),
      );
      expect(result.summary, isNull);
      expect(result.error, 'provider down');
    });

    test('maps aborted summarization to the aborted flag', () async {
      final session = await newSession();
      await session.appendMessage(UserMessage.text('work'));
      final entries = await session.getEntries();

      final result = await generateBranchSummary(
        entries,
        summarize: (request) async =>
            SummarizationResult.failure('aborted', aborted: true),
      );
      expect(result.aborted, isTrue);
      expect(result.summary, isNull);
    });
  });

  group('navigateSessionTree', () {
    test(
      'moves the leaf and prepends the summary to the entered branch',
      () async {
        final session = await newSession();
        final root = await session.appendMessage(UserMessage.text('root'));
        await session.appendMessage(_assistant('detour answer'));
        final detourLeaf = await session.getLeafId();
        await session.moveTo(root);
        await session.appendMessage(UserMessage.text('b1'));

        // Navigate from b1 back to the detour leaf: the b1 side branch gets
        // summarized onto the detour branch.
        final summarizer = _FakeSummarizer('## Goal\n\nExplore b1.');
        final summaryId = await navigateSessionTree(
          session,
          detourLeaf,
          summarize: summarizer.call,
        );

        expect(summaryId, isNotNull);
        expect(await session.getLeafId(), summaryId);
        final record =
            (await session.getEntry(summaryId!))! as BranchSummaryRecord;
        expect(record.fromId, detourLeaf);
        expect(record.summary, contains('## Goal\n\nExplore b1.'));
        expect(record.details, isA<Map>());

        // The entered branch's rebuilt context carries the summary as a
        // user message right after the detour messages.
        final context = await session.buildContextMessages();
        final summaryMessage = context.last as UserMessage;
        expect(summaryMessage.content, startsWith(branchSummaryPrefix));
        expect(summaryMessage.content, contains('## Goal\n\nExplore b1.'));

        // The summarizer was fed the abandoned b1 branch.
        expect(summarizer.prompts.single, contains('[User]: b1'));
      },
    );

    test('is a no-op when navigating to the current leaf', () async {
      final session = await newSession();
      await session.appendMessage(UserMessage.text('root'));
      final leaf = await session.getLeafId();
      final summarizer = _FakeSummarizer('unused');
      final result = await navigateSessionTree(
        session,
        leaf,
        summarize: summarizer.call,
      );
      expect(result, isNull);
      expect(summarizer.prompts, isEmpty);
    });

    test('navigates without a summary when summarization fails', () async {
      final session = await newSession();
      final root = await session.appendMessage(UserMessage.text('root'));
      await session.appendMessage(_assistant('detour'));
      final detourLeaf = await session.getLeafId();
      await session.moveTo(root);
      await session.appendMessage(UserMessage.text('b1'));

      final summaryId = await navigateSessionTree(
        session,
        detourLeaf,
        summarize: (request) async =>
            SummarizationResult.failure('provider down'),
      );
      // Navigation happened (leaf moved) but no branch_summary was written.
      expect(summaryId, isNull);
      expect(await session.getLeafId(), detourLeaf);
      final branch = await session.getBranch();
      expect(branch.whereType<BranchSummaryRecord>(), isEmpty);
    });
  });
}
