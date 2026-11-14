import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// `/handoff` digest generation (gh-2102): the core, host-agnostic half —
/// collecting the session's current branch, generating the editable digest
/// with the branch-digest machinery (handoff preamble), and seeding a fresh
/// session with the digest + relevant-file list. The OLD session must stay
/// untouched: the handoff never appends to it (lossless guarantee).
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

ToolCall _readCall(String path) =>
    ToolCall(id: 'call-read-$path', name: 'read', arguments: {'path': path});

ToolCall _writeCall(String path) =>
    ToolCall(id: 'call-write-$path', name: 'write', arguments: {'path': path});

ToolCall _editCall(String path) =>
    ToolCall(id: 'call-edit-$path', name: 'edit', arguments: {'path': path});

/// A [SummarizeFn] returning a fixed digest and recording its prompts.
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

  group('collectEntriesForHandoff', () {
    test(
      'returns the whole current branch, leaf to root, chronological',
      () async {
        final session = await newSession();
        await session.appendMessage(UserMessage.text('u1'));
        await session.appendMessage(_assistant('a1'));
        await session.appendMessage(UserMessage.text('u2'));

        final entries = await collectEntriesForHandoff(session);

        expect(entries, hasLength(3));
        expect(entries.first, isA<MessageRecord>());
        expect((entries.first as MessageRecord).message, isA<UserMessage>());
        // Newest LAST (chronological) — the summarizer walks it back-to-front.
        final last = entries.last;
        expect(last, isA<MessageRecord>());
        expect((last as MessageRecord).message, isA<UserMessage>());
      },
    );

    test('an empty session has nothing to hand off', () async {
      final session = await newSession();
      expect(await collectEntriesForHandoff(session), isEmpty);
    });

    test('a windowed (resumed) session collects the WHOLE branch, not just '
        'the resident tail — the resume walk must never silently truncate '
        'the digest input (gh-2102 review, BLOCKING)', () async {
      final session = await newSession();
      for (var i = 0; i < 800; i++) {
        await session.appendMessage(UserMessage.text('m$i'));
      }
      // The resume path: every CLI resume/boot opens WINDOWED, and the
      // parity-budget walk leaves only the tail resident.
      final meta = await session.getMetadata();
      final resumed = await repo.open(meta, windowed: true);
      await resumed.ensureCompactionBoundaryResident(tokenBudget: 50);
      final residentBranch = await resumed.getBranch();
      // Bug precondition: the windowed branch IS partial before the fix
      // (the reviewer reproduced 3 of 40 records this way).
      expect(residentBranch.length, lessThan(800));

      final entries = await collectEntriesForHandoff(resumed);

      // The whole conversation is what a handoff carries over: the
      // collect must prime whole-ledger residency first.
      expect(entries, hasLength(800));
    });

    test('a ledger past the whole-ledger bound refuses with the tooLarge '
        'SessionException — hosts degrade loudly, never silently digest a '
        'partial tail (gh-2102 review)', () async {
      final session = await newSession();
      for (var i = 0; i < 800; i++) {
        await session.appendMessage(UserMessage.text('m$i'));
      }
      final meta = await session.getMetadata();
      final resumed = await repo.open(meta, windowed: true);

      await expectLater(
        collectEntriesForHandoff(resumed, maxWholeLedgerBytes: 1),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.tooLarge,
          ),
        ),
      );
    });
  });

  group('generateHandoffDigest', () {
    test('uses the handoff preamble, never the abandoned-branch one', () async {
      final session = await newSession();
      await session.appendMessage(UserMessage.text('u1'));
      final entries = await collectEntriesForHandoff(session);
      final summarizer = _FakeSummarizer('## Goal\nship it');

      final result = await generateHandoffDigest(
        entries,
        summarize: summarizer.call,
      );

      expect(result.isSuccess, isTrue);
      expect(result.summary, contains('## Goal'));
      expect(summarizer.prompts, hasLength(1));
      expect(summarizer.prompts.single, contains('## Goal'));
    });

    test('composed digest carries the handoff preamble + file tags', () async {
      final session = await newSession();
      await session.appendMessage(
        _toolCalls([_readCall('/a/one.dart'), _readCall('/a/two.dart')]),
      );
      await session.appendMessage(
        _toolResult('call-read-/a/one.dart', 'read', 'ok'),
      );
      await session.appendMessage(
        _toolCalls([_writeCall('/a/two.dart'), _editCall('/a/three.dart')]),
      );
      await session.appendMessage(_assistant('done'));
      final entries = await collectEntriesForHandoff(session);

      final result = await generateHandoffDigest(
        entries,
        summarize: _FakeSummarizer('digest body').call,
      );

      expect(result.summary, startsWith(handoffDigestPreamble));
      expect(result.summary, contains('digest body'));
      // The relevant-file list rides the digest text (the session seed is
      // self-contained) and the structured result.
      expect(result.summary, contains('<read-files>'));
      expect(result.summary, contains('/a/one.dart'));
      expect(
        result.readFiles,
        ['/a/one.dart'], // modified files leave the read-only list
      );
      expect(result.modifiedFiles, ['/a/three.dart', '/a/two.dart']);
    });

    test('nested branch-summary file lists accumulate (2+ sources)', () async {
      final session = await newSession();
      await session.appendMessage(_toolCalls([_readCall('/kept.dart')]));
      final collected = await collectEntriesForHandoff(session);
      final entries = [
        ...collected,
        BranchSummaryRecord(
          id: 'nested-branch-summary',
          parentId: collected.last.id,
          timestamp: DateTime.utc(2026),
          fromId: 'elsewhere',
          summary: 'earlier branch checkpoint',
          details: {
            'readFiles': ['/nested-a.dart', '/nested-b.dart'],
            'modifiedFiles': ['/nested-c.dart'],
          },
        ),
      ];

      final result = await generateHandoffDigest(
        entries,
        summarize: _FakeSummarizer('body').call,
      );

      expect(result.readFiles, containsAll(['/kept.dart', '/nested-a.dart']));
      expect(result.modifiedFiles, contains('/nested-c.dart'));
    });

    test('no entries → no digest, reported not thrown', () async {
      final result = await generateHandoffDigest(
        const [],
        summarize: _FakeSummarizer('never called').call,
      );
      expect(result.isSuccess, isFalse);
      expect(result.summary, isNull);
    });

    test('summarizer failure surfaces as an error, never throws', () async {
      final session = await newSession();
      await session.appendMessage(UserMessage.text('u1'));
      final entries = await collectEntriesForHandoff(session);
      Future<SummarizationResult> failing(SummarizationRequest _) async {
        return SummarizationResult.failure('provider down');
      }

      final result = await generateHandoffDigest(entries, summarize: failing);

      expect(result.isSuccess, isFalse);
      expect(result.error, isNotNull);
    });

    test('summarizer abort surfaces as aborted', () async {
      final session = await newSession();
      await session.appendMessage(UserMessage.text('u1'));
      final entries = await collectEntriesForHandoff(session);
      Future<SummarizationResult> aborted(SummarizationRequest _) async {
        return SummarizationResult.failure('cancelled', aborted: true);
      }

      final result = await generateHandoffDigest(entries, summarize: aborted);

      expect(result.aborted, isTrue);
      expect(result.isSuccess, isFalse);
    });

    test('generation is lossless: the session gains no records', () async {
      final session = await newSession();
      await session.appendMessage(UserMessage.text('u1'));
      await session.appendMessage(_assistant('a1'));
      final entries = await collectEntriesForHandoff(session);
      final before = (await session.getEntries()).length;

      await generateHandoffDigest(
        entries,
        summarize: _FakeSummarizer('body').call,
      );

      expect(await session.getEntries(), hasLength(before));
    });

    test('a summarizer window bounds the digest prompt: an over-budget branch '
        'is summarized chunk-wise (fold), every outbound prompt within the '
        'payload budget (gh-2102 review, IMPORTANT)', () async {
      final session = await newSession();
      // One read op (file lists must survive the fold) + a branch whose
      // serialized conversation (~21k tokens) overflows a 32k-window
      // smol role's payload budget (32768 - 16384 reserve).
      await session.appendMessage(UserMessage.text('read /src/one.dart'));
      await session.appendMessage(_toolCalls([_readCall('/src/one.dart')]));
      for (var i = 0; i < 200; i++) {
        await session.appendMessage(UserMessage.text('u$i-${'a' * 380}'));
      }
      final entries = await collectEntriesForHandoff(session);
      final budget = summarizationPayloadBudget(
        32768,
        defaultCompactionSettings,
      );
      expect(
        estimateStringTokens(
          serializeConversation(
            entries
                .map((entry) {
                  return entry is MessageRecord ? entry.message : null;
                })
                .whereType<Message>()
                .toList(),
          ),
        ),
        greaterThan(budget),
      ); // genuinely over-budget

      final summarizer = _FakeSummarizer('FOLD');
      final result = await generateHandoffDigest(
        entries,
        summarize: summarizer.call,
        summarizerWindow: 32768,
      );

      expect(result.isSuccess, isTrue);
      expect(summarizer.prompts, hasLength(greaterThan(1)));
      // The #729 invariant, now on the handoff path too: every outbound
      // prompt fits the summarizer's payload budget.
      for (final prompt in summarizer.prompts) {
        expect(
          estimateStringTokens(prompt),
          lessThanOrEqualTo(budget),
          reason: 'outbound digest payload exceeded the budget',
        );
      }
      // The fold threads: every chunk after the first carries the prior
      // summary as <previous-checkpoint>.
      for (final prompt in summarizer.prompts.sublist(1)) {
        expect(prompt, contains('<previous-checkpoint>'));
        expect(prompt, contains('FOLD'));
      }
      // The composed digest keeps the handoff preamble + the fold + the
      // file lists (file ops accumulate across ALL entries even when
      // the conversation rides chunks).
      expect(result.summary, startsWith(handoffDigestPreamble));
      expect(result.summary, contains('FOLD'));
      expect(result.summary, contains('<read-files>'));
      expect(result.readFiles, ['/src/one.dart']);
    });

    test('a summarizer window over an under-budget branch is a no-op: the '
        'single prompt is byte-identical to the unbounded path '
        '(gh-2102 review)', () async {
      final session = await newSession();
      await session.appendMessage(UserMessage.text('small branch'));
      final entries = await collectEntriesForHandoff(session);

      final bounded = _FakeSummarizer('digest');
      await generateHandoffDigest(
        entries,
        summarize: bounded.call,
        summarizerWindow: 200000,
      );
      final unbounded = _FakeSummarizer('digest');
      await generateHandoffDigest(entries, summarize: unbounded.call);

      expect(bounded.prompts, hasLength(1));
      expect(unbounded.prompts, hasLength(1));
      expect(bounded.prompts.single, unbounded.prompts.single);
    });

    test('a single message bigger than the budget is truncated with the '
        'explicit note, never silently (gh-2102 review)', () async {
      final session = await newSession();
      await session.appendMessage(UserMessage.text('g' * 8000));
      final entries = await collectEntriesForHandoff(session);

      final summarizer = _FakeSummarizer('FOLD');
      final result = await generateHandoffDigest(
        entries,
        summarize: summarizer.call,
        summarizerWindow: 2000, // budget = 1000 tokens
      );

      expect(result.isSuccess, isTrue);
      expect(summarizer.prompts, hasLength(1)); // one oversized chunk
      expect(summarizer.prompts.single, contains('more characters truncated'));
    });
  });

  group('seedHandoffRecord', () {
    test('the fresh session context carries digest + file list', () async {
      final fresh = await newSession();
      await seedHandoffRecord(
        fresh,
        digest: '## Goal\nfinish it',
        readFiles: ['/a/one.dart'],
        modifiedFiles: ['/a/two.dart', '/a/three.dart'],
      );

      final context = await fresh.buildContextMessages();
      expect(context, hasLength(1));
      expect(context.single, isA<UserMessage>());
      final text = (context.single as UserMessage).content as String;
      expect(text, contains('## Goal'));
      expect(text, contains('finish it'));

      final record = (await fresh.getEntries()).single;
      expect(record, isA<CustomMessageRecord>());
      final custom = record as CustomMessageRecord;
      expect(custom.customType, handoffDigestCustomType);
      final details = custom.details! as Map;
      expect(details['readFiles'], ['/a/one.dart']);
      expect(details['modifiedFiles'], ['/a/two.dart', '/a/three.dart']);
    });
  });
}
