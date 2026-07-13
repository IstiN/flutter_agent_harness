import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage _assistant(String text, {Usage usage = Usage.zero}) {
  return AssistantMessage(
    content: [TextContent(text: text)],
    api: 'openai-completions',
    provider: 'openrouter',
    model: 'm1',
    usage: usage,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

/// Fake summarizer: records every request, replays scripted results.
class _FakeSummarizer {
  _FakeSummarizer(this.results);

  final List<SummarizationResult> results;
  final requests = <SummarizationRequest>[];

  Future<SummarizationResult> call(SummarizationRequest request) async {
    requests.add(request);
    return results.removeAt(0);
  }
}

void main() {
  group('generateSummary', () {
    test('builds pi prompt: conversation tags + structured prompt', () async {
      final fake = _FakeSummarizer([SummarizationResult.success('SUMMARY')]);
      final text = await generateSummary([
        UserMessage.text('do the thing'),
        _assistant('working on it'),
      ], summarize: fake.call);
      expect(text, 'SUMMARY');
      final prompt = fake.requests.single.prompt;
      expect(prompt, startsWith('<conversation>\n'));
      expect(prompt, contains('[User]: do the thing'));
      expect(prompt, contains('[Assistant]: working on it'));
      expect(prompt, contains('</conversation>'));
      expect(prompt, endsWith(summarizationPrompt));
    });

    test('previous summary switches to the update prompt', () async {
      final fake = _FakeSummarizer([SummarizationResult.success('UPDATED')]);
      await generateSummary(
        [UserMessage.text('more work')],
        summarize: fake.call,
        previousSummary: 'OLD SUMMARY',
      );
      final prompt = fake.requests.single.prompt;
      expect(
        prompt,
        contains('<previous-summary>\nOLD SUMMARY\n</previous-summary>'),
      );
      expect(prompt, endsWith(updateSummarizationPrompt));
    });

    test('custom instructions are appended as Additional focus', () async {
      final fake = _FakeSummarizer([SummarizationResult.success('S')]);
      await generateSummary(
        [UserMessage.text('x')],
        summarize: fake.call,
        customInstructions: 'focus on tests',
      );
      expect(
        fake.requests.single.prompt,
        endsWith('$summarizationPrompt\n\nAdditional focus: focus on tests'),
      );
    });

    test('LLM failure throws summarizationFailed (never swallows)', () async {
      final fake = _FakeSummarizer([
        SummarizationResult.failure('provider down'),
      ]);
      expect(
        () => generateSummary([UserMessage.text('x')], summarize: fake.call),
        throwsA(
          isA<CompactionException>()
              .having(
                (e) => e.code,
                'code',
                CompactionErrorCode.summarizationFailed,
              )
              .having((e) => e.message, 'message', contains('provider down')),
        ),
      );
    });

    test('aborted LLM call throws aborted', () async {
      final fake = _FakeSummarizer([
        SummarizationResult.failure('cancelled', aborted: true),
      ]);
      expect(
        () => generateSummary([UserMessage.text('x')], summarize: fake.call),
        throwsA(
          isA<CompactionException>().having(
            (e) => e.code,
            'code',
            CompactionErrorCode.aborted,
          ),
        ),
      );
    });

    test('a throwing summarizer becomes summarizationFailed', () async {
      Future<SummarizationResult> boom(SummarizationRequest _) async {
        throw StateError('boom');
      }

      expect(
        () => generateSummary([UserMessage.text('x')], summarize: boom),
        throwsA(
          isA<CompactionException>().having(
            (e) => e.code,
            'code',
            CompactionErrorCode.summarizationFailed,
          ),
        ),
      );
    });

    test('cancel token is forwarded to the summarizer', () async {
      final fake = _FakeSummarizer([SummarizationResult.success('S')]);
      final source = CancelTokenSource();
      await generateSummary(
        [UserMessage.text('x')],
        summarize: fake.call,
        cancelToken: source.token,
      );
      expect(fake.requests.single.cancelToken, source.token);
    });
  });

  group('streamFunctionSummarizer', () {
    const model = Model(
      id: 'm',
      api: 'a',
      provider: 'p',
      baseUrl: '',
      contextWindow: 1000,
      maxTokens: 100,
    );

    AssistantMessageEventStream streamOf(List<AssistantMessageEvent> events) {
      final stream = AssistantMessageEventStream();
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
      return stream;
    }

    AssistantMessage responseOf(
      String text, {
      StopReason stopReason = StopReason.stop,
      String? errorMessage,
    }) {
      return AssistantMessage(
        content: [TextContent(text: text)],
        api: 'a',
        provider: 'p',
        model: 'm',
        usage: Usage.zero,
        stopReason: stopReason,
        errorMessage: errorMessage,
        timestamp: DateTime.utc(2026),
      );
    }

    test('joins text blocks on success and sends the system prompt', () async {
      Context? captured;
      final summarize = streamFunctionSummarizer((
        model,
        context, {
        cancelToken,
      }) {
        captured = context;
        final message = responseOf('line1');
        return streamOf([
          StartEvent(partial: message),
          DoneEvent(reason: StopReason.stop, message: message),
        ]);
      }, model);
      final result = await summarize(
        const SummarizationRequest(prompt: 'PROMPT'),
      );
      expect(result.isSuccess, isTrue);
      expect(result.text, 'line1');
      expect(captured?.systemPrompt, summarizationSystemPrompt);
      expect(captured?.messages.single, isA<UserMessage>());
      expect((captured!.messages.single as UserMessage).content, 'PROMPT');
    });

    test('error stop reason maps to failure', () async {
      final summarize = streamFunctionSummarizer((
        model,
        context, {
        cancelToken,
      }) {
        final message = responseOf(
          '',
          stopReason: StopReason.error,
          errorMessage: 'rate limited',
        );
        return streamOf([
          StartEvent(partial: message),
          ErrorEvent(reason: StopReason.error, error: message),
        ]);
      }, model);
      final result = await summarize(const SummarizationRequest(prompt: 'P'));
      expect(result.isSuccess, isFalse);
      expect(result.error, contains('rate limited'));
      expect(result.isAborted, isFalse);
    });

    test('aborted stop reason maps to aborted failure', () async {
      final summarize = streamFunctionSummarizer((
        model,
        context, {
        cancelToken,
      }) {
        final message = responseOf('', stopReason: StopReason.aborted);
        return streamOf([
          StartEvent(partial: message),
          ErrorEvent(reason: StopReason.aborted, error: message),
        ]);
      }, model);
      final result = await summarize(const SummarizationRequest(prompt: 'P'));
      expect(result.isAborted, isTrue);
    });

    test('a throwing StreamFunction becomes a failure result', () async {
      final summarize = streamFunctionSummarizer((
        model,
        context, {
        cancelToken,
      }) {
        throw StateError('adapter exploded');
      }, model);
      final result = await summarize(const SummarizationRequest(prompt: 'P'));
      expect(result.isSuccess, isFalse);
      expect(result.error, contains('adapter exploded'));
    });
  });

  group('CompactionManager.compact', () {
    CompactionPreparation preparationOf({
      List<Message>? messagesToSummarize,
      List<Message> turnPrefixMessages = const [],
      bool isSplitTurn = false,
      String? previousSummary,
    }) {
      return CompactionPreparation(
        firstKeptEntryId: 'kept-1',
        messagesToSummarize: messagesToSummarize ?? [UserMessage.text('old')],
        turnPrefixMessages: turnPrefixMessages,
        isSplitTurn: isSplitTurn,
        tokensBefore: 50000,
        previousSummary: previousSummary,
        readFiles: const ['/a.dart'],
        modifiedFiles: const ['/b.dart'],
        settings: defaultCompactionSettings,
      );
    }

    test('single summary plus file-operation metadata', () async {
      final fake = _FakeSummarizer([SummarizationResult.success('SUM')]);
      final manager = CompactionManager(summarize: fake.call);
      final result = await manager.compact(preparationOf());
      expect(result.summary, startsWith('SUM'));
      expect(result.summary, contains('<read-files>\n/a.dart\n</read-files>'));
      expect(
        result.summary,
        contains('<modified-files>\n/b.dart\n</modified-files>'),
      );
      expect(result.firstKeptEntryId, 'kept-1');
      expect(result.tokensBefore, 50000);
      expect(result.details, {
        'readFiles': ['/a.dart'],
        'modifiedFiles': ['/b.dart'],
      });
      expect(fake.requests, hasLength(1));
    });

    test('split turn: history and turn prefix summarized separately', () async {
      final fake = _FakeSummarizer([
        SummarizationResult.success('HISTORY'),
        SummarizationResult.success('PREFIX'),
      ]);
      final manager = CompactionManager(summarize: fake.call);
      final result = await manager.compact(
        preparationOf(
          isSplitTurn: true,
          turnPrefixMessages: [UserMessage.text('prefix')],
        ),
      );
      expect(
        result.summary,
        startsWith(
          'HISTORY\n\n---\n\n**Turn Context (split turn):**\n\nPREFIX',
        ),
      );
      expect(fake.requests, hasLength(2));
      expect(fake.requests[1].prompt, contains(turnPrefixSummarizationPrompt));
    });

    test('split turn with empty history uses pi placeholder', () async {
      final fake = _FakeSummarizer([SummarizationResult.success('PREFIX')]);
      final manager = CompactionManager(summarize: fake.call);
      final result = await manager.compact(
        preparationOf(
          messagesToSummarize: const [],
          isSplitTurn: true,
          turnPrefixMessages: [UserMessage.text('prefix')],
        ),
      );
      expect(
        result.summary,
        startsWith(
          'No prior history.\n\n---\n\n**Turn Context (split turn):**',
        ),
      );
      expect(fake.requests, hasLength(1));
    });

    test('failure aborts the run: no partial summary returned', () async {
      final fake = _FakeSummarizer([SummarizationResult.failure('down')]);
      final manager = CompactionManager(summarize: fake.call);
      expect(
        () => manager.compact(preparationOf()),
        throwsA(isA<CompactionException>()),
      );
    });

    test('previous summary is threaded into the history prompt', () async {
      final fake = _FakeSummarizer([SummarizationResult.success('SUM')]);
      final manager = CompactionManager(summarize: fake.call);
      await manager.compact(preparationOf(previousSummary: 'EARLIER'));
      expect(fake.requests.single.prompt, contains('EARLIER'));
      expect(fake.requests.single.prompt, contains('<previous-summary>'));
    });
  });

  group('CompactionManager.prepareCompaction', () {
    MessageRecord recordOf(String id, Message message) {
      return MessageRecord(
        id: id,
        parentId: null,
        timestamp: DateTime.utc(2026),
        message: message,
      );
    }

    UserMessage bigUser(String id) => UserMessage.text('$id${'a' * 400}');

    test('empty path or trailing compaction: nothing to prepare', () {
      final manager = CompactionManager(
        summarize: (_) async => SummarizationResult.success(''),
      );
      expect(manager.prepareCompaction(const [], tokensBefore: 0), isNull);
      final trailing = [
        recordOf('m1', bigUser('u')),
        CompactionRecord(
          id: 'c1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          summary: 's',
          firstKeptEntryId: 'm1',
          tokensBefore: 10,
        ),
      ];
      expect(manager.prepareCompaction(trailing, tokensBefore: 10), isNull);
    });

    test('splits path into summarized and kept regions', () {
      final manager = CompactionManager(
        summarize: (_) async => SummarizationResult.success(''),
      );
      final path = [
        recordOf('m1', bigUser('u1')),
        recordOf('m2', _assistant('b' * 400)),
        recordOf('m3', bigUser('u3')),
        recordOf('m4', _assistant('b' * 400)),
      ];
      final preparation = manager.prepareCompaction(
        path,
        tokensBefore: 12345,
        settings: const CompactionSettings(
          enabled: true,
          reserveTokens: 16384,
          keepRecentTokens: 150,
        ),
      )!;
      // 100 tokens each; budget 150 -> cut at m3 (user).
      expect(preparation.firstKeptEntryId, 'm3');
      expect(preparation.isSplitTurn, isFalse);
      expect(preparation.messagesToSummarize, hasLength(2));
      expect(preparation.turnPrefixMessages, isEmpty);
      expect(preparation.tokensBefore, 12345);
      expect(preparation.previousSummary, isNull);
    });

    test('previous compaction seeds summary and boundary', () {
      final manager = CompactionManager(
        summarize: (_) async => SummarizationResult.success(''),
      );
      final path = [
        recordOf('m1', bigUser('u1')),
        recordOf('m2', _assistant('b' * 400)),
        CompactionRecord(
          id: 'c1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          summary: 'FIRST SUMMARY',
          firstKeptEntryId: 'm2',
          tokensBefore: 1000,
          details: {
            'readFiles': ['/old.dart'],
            'modifiedFiles': <String>[],
          },
        ),
        recordOf('m2b', _assistant('b' * 400)),
        recordOf('m3', bigUser('u3')),
        recordOf('m4', _assistant('b' * 400)),
      ];
      final preparation = manager.prepareCompaction(
        path,
        tokensBefore: 900,
        settings: const CompactionSettings(
          enabled: true,
          reserveTokens: 16384,
          keepRecentTokens: 150,
        ),
      )!;
      expect(preparation.previousSummary, 'FIRST SUMMARY');
      // The summarized region starts at the previous firstKeptEntryId (m2)
      // and the compaction record itself never enters the summary.
      expect(preparation.messagesToSummarize, hasLength(2));
      expect(
        preparation.messagesToSummarize,
        everyElement(isA<AssistantMessage>()),
      );
      // File ops accumulate across compactions (pi behavior).
      expect(preparation.readFiles, contains('/old.dart'));
    });

    test('custom and branch summary records project into the summary', () {
      final manager = CompactionManager(
        summarize: (_) async => SummarizationResult.success(''),
      );
      final path = [
        CustomMessageRecord(
          id: 'cm',
          parentId: null,
          timestamp: DateTime.utc(2026),
          customType: 'note',
          content: 'remember this',
          display: false,
        ),
        BranchSummaryRecord(
          id: 'bs-empty',
          parentId: null,
          timestamp: DateTime.utc(2026),
          fromId: 'x',
          summary: '',
        ),
        BranchSummaryRecord(
          id: 'bs',
          parentId: null,
          timestamp: DateTime.utc(2026),
          fromId: 'x',
          summary: 'came back from a branch',
        ),
        recordOf('m1', bigUser('u1')),
        recordOf('m2', _assistant('b' * 400)),
        recordOf('m3', bigUser('u3')),
        recordOf('m4', _assistant('b' * 400)),
      ];
      final preparation = manager.prepareCompaction(
        path,
        tokensBefore: 1000,
        settings: const CompactionSettings(
          enabled: true,
          reserveTokens: 16384,
          keepRecentTokens: 150,
        ),
      )!;
      // Cut at m3; summarized = custom message + branch summary (the empty
      // one is skipped) + m1 + m2.
      expect(preparation.firstKeptEntryId, 'm3');
      expect(preparation.messagesToSummarize, hasLength(4));
      final custom = preparation.messagesToSummarize[0] as UserMessage;
      expect(custom.content, 'remember this');
      final branch = preparation.messagesToSummarize[1] as UserMessage;
      expect(
        branch.content,
        '$branchSummaryPrefix${'came back from a branch'}$branchSummarySuffix',
      );
    });

    test(
      'orphaned previous firstKeptEntryId falls back past the compaction',
      () {
        final manager = CompactionManager(
          summarize: (_) async => SummarizationResult.success(''),
        );
        final path = [
          CompactionRecord(
            id: 'c1',
            parentId: null,
            timestamp: DateTime.utc(2026),
            summary: 'OLD',
            firstKeptEntryId: 'ghost',
            tokensBefore: 10,
          ),
          recordOf('m1', bigUser('u1')),
          recordOf('m2', bigUser('u2')),
        ];
        final preparation = manager.prepareCompaction(
          path,
          tokensBefore: 500,
          settings: const CompactionSettings(
            enabled: true,
            reserveTokens: 16384,
            keepRecentTokens: 50,
          ),
        )!;
        // Boundary starts right after the compaction record; the cut keeps m2
        // and summarizes m1.
        expect(preparation.firstKeptEntryId, 'm2');
        expect(preparation.previousSummary, 'OLD');
        expect(preparation.messagesToSummarize, hasLength(1));
      },
    );

    test('split turn preparation collects turn prefix messages', () {
      final manager = CompactionManager(
        summarize: (_) async => SummarizationResult.success(''),
      );
      final path = [
        recordOf('m1', bigUser('u1')),
        recordOf('m2', _assistant('b' * 400)),
        recordOf('m3', bigUser('u3')),
        recordOf(
          'm4',
          AssistantMessage(
            content: [
              const TextContent(text: 'thinking'),
              ToolCall(id: 'c1', name: 'read', arguments: {'path': '/x.dart'}),
            ],
            api: 'openai-completions',
            provider: 'openrouter',
            model: 'm1',
            usage: Usage.zero,
            stopReason: StopReason.stop,
            timestamp: DateTime.utc(2026),
          ),
        ),
        recordOf(
          'm5',
          ToolResultMessage(
            toolCallId: 'c1',
            toolName: 'read',
            content: [TextContent(text: 'r' * 800)],
            isError: false,
            timestamp: DateTime.utc(2026),
          ),
        ),
        recordOf('m6', _assistant('b' * 400)),
      ];
      // m6 (100), m5 (200 >= 150) -> budget exhausts at m5; cut moves to the
      // next valid cut point m6 (assistant) -> split turn starting at m3.
      final preparation = manager.prepareCompaction(
        path,
        tokensBefore: 2000,
        settings: const CompactionSettings(
          enabled: true,
          reserveTokens: 16384,
          keepRecentTokens: 150,
        ),
      )!;
      expect(preparation.firstKeptEntryId, 'm6');
      expect(preparation.isSplitTurn, isTrue);
      // History = m1, m2. Turn prefix = m3..m5.
      expect(preparation.messagesToSummarize, hasLength(2));
      expect(preparation.turnPrefixMessages, hasLength(3));
      // File ops come from both regions.
      expect(preparation.readFiles, contains('/x.dart'));
    });
  });
}
