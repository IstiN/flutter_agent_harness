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
