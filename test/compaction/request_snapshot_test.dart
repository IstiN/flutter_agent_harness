// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// GOAL #2394 — `RequestSnapshot` (S0, AC2): captured at the main-send
/// seam, last wins, a COPY of the messages, frozen index resolution (UT-23,
/// E31), invalidation on model switch / restore / successful run (IT-06,
/// E20, E32) and the transcript/tag-epoch alignment of the session
/// projection (AC8).

library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart';
import 'package:test/test.dart';

Model _model(
  String id, {
  String provider = 'p',
  String baseUrl = 'https://x',
}) => Model(
  provider: provider,
  id: id,
  baseUrl: baseUrl,
  api: 'openai-completions',
  contextWindow: 200000,
  maxTokens: 8192,
);

AssistantMessage _assistant(String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'openai-completions',
  provider: 'p',
  model: 'm',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

ToolResultMessage _result(String text) => ToolResultMessage(
  toolCallId: 'c1',
  toolName: 'bash',
  content: [TextContent(text: text)],
  isError: false,
  timestamp: DateTime.utc(2026),
);

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  RequestSnapshot snap({
    Model? model,
    List<Message>? messages,
    TranscriptSeqMap? seqMap,
    DateTime? sentAt,
  }) => RequestSnapshot(
    model: model ?? _model('m'),
    messages:
        messages ?? [UserMessage.text('ask', timestamp: DateTime.utc(2026))],
    systemPrompt: 'sys',
    seqMap:
        seqMap ??
        TranscriptSeqMap(headSeqs: const [2], index: RecordSeqIndex(const [])),
    sentAt: sentAt ?? DateTime.utc(2026, 1, 1, 12),
  );

  group('AC2 snapshot shape', () {
    test(
      'messages are a private copy; the context extends without mutating',
      () {
        final source = [UserMessage.text('ask', timestamp: DateTime.utc(2026))];
        final snapshot = snap(messages: source);
        source.add(UserMessage.text('late', timestamp: DateTime.utc(2026)));
        expect(snapshot.messages, hasLength(1));
        expect(
          () => snapshot.messages.add(_assistant('x')),
          throwsUnsupportedError,
        );
        final context = snapshot.toContext(
          extraMessages: [
            UserMessage.text('instruction', timestamp: DateTime.utc(2026)),
          ],
        );
        expect(context.messages, hasLength(2));
        expect(context.systemPrompt, 'sys');
        expect(snapshot.messages, hasLength(1));
        expect(snapshot.prefixLength, 1);
      },
    );
  });

  group('UT-23 hide-id resolution against the frozen index', () {
    final records = [
      MessageRecord(
        id: 'a',
        parentId: null,
        timestamp: DateTime.utc(2026),
        message: UserMessage.text('ask', timestamp: DateTime.utc(2026)),
      ),
      MessageRecord(
        id: 'b',
        parentId: null,
        timestamp: DateTime.utc(2026),
        message: _assistant('reply'),
      ),
    ];

    test('seq → record id through the epoch index; unknown never resolves', () {
      final snapshot = snap(
        seqMap: TranscriptSeqMap(
          headSeqs: const [2, 3],
          index: RecordSeqIndex(records),
        ),
      );
      expect(snapshot.recordIdAt(2), 'a');
      expect(snapshot.recordIdAt(3), 'b');
      expect(snapshot.recordIdAt(4), isNull, reason: 'beyond the epoch');
      expect(snapshot.recordIdAt(0), isNull);
      expect(snapshot.recordIdAt(-1), isNull);
    });

    test(
      'E31: a windowed loadOlder / hard cap between S0 and the reply cannot move the ids',
      () {
        final snapshot = snap(
          seqMap: TranscriptSeqMap(
            headSeqs: const [2],
            index: RecordSeqIndex(records),
          ),
        );
        // A fresh index over a shifted chain (older records dropped) — the
        // engine must NOT consult it: the frozen snapshot keeps the id.
        final shifted = RecordSeqIndex([records[1]]);
        expect(shifted.recordAt(2)?.id, 'b');
        expect(snapshot.recordIdAt(2), 'a');
      },
    );
  });

  group('IT-06 snapshot lifecycle', () {
    test('last send wins', () {
      final store = RequestSnapshotStore();
      store.capture(
        snap(
          messages: [UserMessage.text('one', timestamp: DateTime.utc(2026))],
        ),
      );
      store.capture(
        snap(
          messages: [UserMessage.text('two', timestamp: DateTime.utc(2026))],
        ),
      );
      expect((store.current!.messages.single as UserMessage).content, 'two');
      expect(store.invalidReason, isNull);
    });

    test(
      'E32: a model switch (prepareNextTurn) invalidates until the next send',
      () {
        final store = RequestSnapshotStore();
        store.capture(snap(model: _model('m')));
        expect(store.validFor(_model('m')), isNotNull);
        expect(store.validFor(_model('m2')), isNull);
        expect(store.validFor(_model('m', baseUrl: 'https://other')), isNull);
        // The next main send re-captures under the new model.
        store.capture(snap(model: _model('m2')));
        expect(store.validFor(_model('m2')), isNotNull);
      },
    );

    test(
      'E20: a branch switch / restore and a successful run invalidate; a failed run keeps it',
      () {
        final store = RequestSnapshotStore();
        store.capture(snap());
        store.invalidate('branch switched');
        expect(store.current, isNull);
        expect(store.invalidReason, 'branch switched');
        store.capture(snap());
        expect(
          store.current,
          isNotNull,
          reason: 'a failed run appends nothing — S0 stays valid',
        );
        store.invalidate('compaction ran');
        expect(store.validFor(_model('m')), isNull);
      },
    );

    test('bucket is a report signal: warm inside the TTL, cold after', () {
      final sentAt = DateTime.utc(2026, 1, 1, 12);
      final snapshot = snap(sentAt: sentAt);
      expect(
        snapshot.bucket(now: sentAt.add(const Duration(minutes: 4))),
        'warm',
      );
      expect(
        snapshot.bucket(now: sentAt.add(const Duration(minutes: 6))),
        'cold',
      );
    });
  });

  group('transcript projection carries the tag epoch', () {
    test(
      'seqs align with the projected messages; level-0 tail blocks are null',
      () async {
        final session = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        final a = await session.appendMessage(UserMessage.text('fix 2321'));
        final b = await session.appendMessage(
          AssistantMessage(
            content: [
              TextContent(text: 'looking'),
              ToolCall(id: 'c1', name: 'read', arguments: const {}),
            ],
            api: 'openai-completions',
            provider: 'p',
            model: 'm',
            usage: Usage.zero,
            stopReason: StopReason.toolUse,
            timestamp: DateTime.utc(2026),
          ),
        );
        final c = await session.appendMessage(_result('x' * 400));
        await session.appendHiddenRange(recordIds: [c]);
        final projection = await session.buildTranscriptProjection();
        final messages = await session.buildContextMessages();
        expect(projection.messages.length, messages.length);
        expect(projection.recordSeqs, hasLength(messages.length));
        expect(projection.recordSeqs, [2, 3, 4]);
        expect(projection.seqMap.recordIdAt(0), a);
        expect(projection.seqMap.recordIdAt(1), b);
        expect(projection.seqMap.recordIdAt(2), c);
        // The tagged wire copy carries the alias on the hidden marker too.
        final tagged = tagTranscript(projection.messages, projection.seqMap);
        expect((tagged[0] as UserMessage).content, 'm2 fix 2321');
        expect(
          ((tagged[2] as ToolResultMessage).content.single as TextContent).text,
          startsWith('m4 [4:hidden'),
        );
        // The transcript itself stays untagged.
        expect((messages[0] as UserMessage).content, 'fix 2321');
      },
    );
  });
}
