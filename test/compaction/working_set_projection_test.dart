// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-210 / gh-2423 — the working set and the level-0 tail block.
///
/// Since issue #2423 (C1) the agent's working-set TEXT rides the SYSTEM
/// channel of every request (`AgentLoopConfig.workingSetProvider` → a
/// suffix on the system prompt) and the tail block carries only the
/// recently-touched-files section. This file pins:
///
/// - the tail block: files only, no goal line, nothing without a
///   compaction boundary (AC4);
/// - the hide-protection contract (I1 / AC3): the `custom` snapshot is
///   invisible to every hide path — judge hide, deterministic fallback,
///   checkpoint fold, LRU re-hide, agent hide, emergency relief — and the
///   session still reads the text byte-for-byte after each of them;
/// - the system channel (I2 / AC2): through a real `Agent` loop the block
///   is in `systemPrompt` of every request, never a message, survives a
///   hide and a process restart (a new agent + store over the same
///   file), and is absent (byte-identical prompt) without a snapshot;
/// - the windowed-scan fallback and the append-only session survival.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:flutter_agent_harness/src/compaction/structured/ledger.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart';
import 'package:test/test.dart';

import '../support/scripted_stream_harness.dart';

const _model = Model(
  id: 'm1',
  api: 'anthropic-messages',
  provider: 'p',
  baseUrl: 'http://localhost:1',
  contextWindow: 8000,
  maxTokens: 4096,
);

const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 2000,
  keepRecentTokens: 2000,
);

const _notes =
    'decisions: fix the login crash; red list: never push; '
    'next: update the changelog';

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) =>
    AssistantMessage(
      content: [
        TextContent(text: text),
        ...?calls,
      ],
      api: 'anthropic-messages',
      provider: 'p',
      model: 'm1',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026),
    );

ToolResultMessage _result(String callId, String name, String text) =>
    ToolResultMessage(
      toolCallId: callId,
      toolName: name,
      content: [TextContent(text: text)],
      isError: false,
      timestamp: DateTime.utc(2026),
    );

String _textOf(Message m) =>
    m is UserMessage && m.content is String ? m.content as String : '';

bool _isFilesBlock(Message m) =>
    _textOf(m).startsWith('<system-notice>\nrecently touched files');

/// The bug-fix-shaped over-window history of the structured tests, plus a
/// `write` pair so the files section has a path to re-inject.
Future<(Session, AgentState)> bugSession(
  JsonlSessionRepo repo, {
  int fillers = 12,
}) async {
  final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
  await session.appendMessage(UserMessage.text('fix the login crash'));
  await session.appendMessage(
    _assistant(
      'looking',
      calls: [ToolCall(id: 'c1', name: 'read', arguments: {})],
    ),
  );
  await session.appendMessage(_result('c1', 'read', 'x' * 16000));
  await session.appendMessage(
    _assistant(
      'writing the fix',
      calls: [
        ToolCall(
          id: 'c2',
          name: 'write',
          arguments: {'path': 'lib/auth.dart', 'content': 'x'},
        ),
      ],
    ),
  );
  await session.appendMessage(_result('c2', 'write', 'ok'));
  await session.appendMessage(
    _assistant(
      'running',
      calls: [ToolCall(id: 'c3', name: 'bash', arguments: {})],
    ),
  );
  await session.appendMessage(_result('c3', 'bash', 'y' * 12000));
  for (var i = 0; i < fillers; i++) {
    await session.appendMessage(_assistant('filler analysis $i'));
  }
  final messages = await session.buildContextMessages();
  return (session, AgentState(model: _model, messages: messages));
}

/// Writes one working-set snapshot the way the `working_set` tool does.
Future<void> saveWorkingSet(Session session, String text) =>
    session.appendCustomEntry(
      customType: workingSetRecordType,
      data: WorkingSetSnapshot(
        text: text,
        updatedAt: DateTime.utc(2026),
      ).toPayload(),
    );

/// I1 + I2 after a hide tier: the session still reads the text
/// byte-for-byte, and the text never became a chat message.
Future<void> expectWorkingSetIntact(
  Session session,
  List<Message> messages,
) async {
  final snapshot = await session.workingSetSnapshot();
  expect(snapshot, isNotNull, reason: 'the snapshot survives the tier');
  expect(snapshot!.text, _notes);
  expect(
    messages.where((m) => _textOf(m).contains(_notes)),
    isEmpty,
    reason: 'the working set is system channel, never a message (I2)',
  );
}

/// A judge that hides EVERY seq it can see (exempt/protected-tail picks
/// fall out in validation) — the strongest judge a run can face.
Future<String> Function(String, [CancelToken?]) hideEverythingJudge() =>
    (ledgerText, [cancelToken]) async {
      final ids = RegExp(
        r'\[(\d+)\]',
      ).allMatches(ledgerText).map((m) => m.group(1)!).toSet();
      return '[${ids.join(',')}]';
    };

/// A real `Agent` loop over the session's store: every request [stream]
/// receives is recorded.
Agent loopAgent(Session session, FakeStreamFunction stream) => Agent(
  model: _model,
  systemPrompt: 'You are a coding agent.',
  streamFunction: stream.call,
  toolRegistry: ToolRegistry(const []),
  workingSetStore: SessionWorkingSetStore(session: () async => session),
);

/// The local `HH:MM` of a snapshot time (the block header's clock).
String clockOf(DateTime utc) {
  final local = utc.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  group('level-0 tail block (files only)', () {
    test('a working-set record never renders as a message — the text is '
        'system channel', () async {
      final (session, _) = await bugSession(repo);
      await saveWorkingSet(session, _notes);
      final messages = await session.buildContextMessages();
      // No compaction boundary → no files section either: the
      // projection is exactly the pre-gh-210 shape.
      final entries = await session.getEntries();
      final lastMessage = entries.lastWhere((e) => e is MessageRecord);
      expect(messages.last, (lastMessage as MessageRecord).message);
      expect(messages.where((m) => _textOf(m).contains(_notes)), isEmpty);
      // The session reads the snapshot back for the request build.
      expect((await session.workingSetSnapshot())!.text, _notes);
    });

    test(
      'post-compaction the touched files re-inject as path references',
      () async {
        final (session, _) = await bugSession(repo);
        await session.appendHiddenRange(
          recordIds: [
            (await session.getEntries())[1].id,
            (await session.getEntries())[2].id,
          ],
        );
        final messages = await session.buildContextMessages();
        expect(_isFilesBlock(messages.last), isTrue);
        final block = _textOf(messages.last);
        expect(block, contains('- lib/auth.dart'));
        expect(block, contains('re-read on demand'));
        // AC4: the heading lost the words "working set".
        expect(block, isNot(contains('working set')));
      },
    );

    test('a session with no compaction boundary renders no block', () async {
      final (session, _) = await bugSession(repo);
      final messages = await session.buildContextMessages();
      expect(_isFilesBlock(messages.last), isFalse);
      final entries = await session.getEntries();
      expect(messages.last, (entries.last as MessageRecord).message);
    });

    test(
      'the obligations block stays ahead of the files at the tail',
      () async {
        final (session, _) = await bugSession(repo);
        final entries = await session.getEntries();
        await session.appendHiddenRange(
          recordIds: [entries[1].id, entries[2].id],
        );
        await session.appendCustomEntry(
          customType: obligationsLedgerRecordType,
          data: ObligationsLedger([
            ObligationEntry(
              id: 'obl-1',
              kind: ObligationKind.ownerRule,
              text: 'never push to main',
              sourceRecordId: 'rec-1',
              createdAt: DateTime.utc(2026),
            ),
          ]).toPayload(),
        );
        final messages = await session.buildContextMessages();
        final notices = messages
            .map(_textOf)
            .where((t) => t.startsWith('<system-notice>'))
            .toList();
        expect(notices, hasLength(2));
        expect(notices.first, contains('obligations'));
        expect(_isFilesBlock(messages.last), isTrue);
      },
    );

    test('the classic engine boundary also re-injects the files', () async {
      final (session, _) = await bugSession(repo, fillers: 4);
      final entries = await session.getEntries();
      await session.appendCompaction(
        summary: 'the earlier history, summarized',
        firstKeptEntryId: entries[entries.length - 3].id,
        tokensBefore: 40000,
      );
      final messages = await session.buildContextMessages();
      expect(_isFilesBlock(messages.last), isTrue);
      expect(_textOf(messages.last), contains('- lib/auth.dart'));
    });

    test('MIXED shape: classic-folded writes re-inject under structured hides '
        'too (the structured branch forwards the classic drop)', () async {
      final (session, _) = await bugSession(repo, fillers: 4);
      final entries = await session.getEntries();
      await session.appendHiddenRange(
        recordIds: [entries[5].id, entries[6].id],
      );
      await session.appendCompaction(
        summary: 'the earlier history, summarized',
        firstKeptEntryId: entries[entries.length - 2].id,
        tokensBefore: 40000,
      );
      final messages = await session.buildContextMessages();
      expect(_isFilesBlock(messages.last), isTrue);
      expect(_textOf(messages.last), contains('- lib/auth.dart'));
      expect(validateToolPairing(messages), isEmpty);
    });

    test('WINDOWED: a snapshot below the resident tail still loads '
        '(raw-scan fallback, the #488 class)', () async {
      final (session, _) = await bugSession(repo);
      await saveWorkingSet(session, _notes);
      for (var i = 0; i < 650; i++) {
        await session.appendMessage(UserMessage.text('filler $i'));
      }
      final meta = await session.getMetadata();
      final windowed = await repo.open(meta, windowed: true);
      // Sanity: the resident view has no snapshot at all.
      expect(latestWorkingSetIn(await windowed.getEntries()), isNull);
      expect((await windowed.workingSetSnapshot())!.text, _notes);
      // The scan runs once per session instance (a snapshot-less resident
      // view must not re-read the file on every request).
      expect((await windowed.workingSetSnapshot())!.text, _notes);
    });

    test('a snapshot-less windowed session answers null, once', () async {
      final (session, _) = await bugSession(repo, fillers: 0);
      for (var i = 0; i < 650; i++) {
        await session.appendMessage(UserMessage.text('filler $i'));
      }
      final meta = await session.getMetadata();
      final windowed = await repo.open(meta, windowed: true);
      expect(await windowed.workingSetSnapshot(), isNull);
      expect(await windowed.workingSetSnapshot(), isNull);
    });
  });

  group('hide protection — the snapshot survives every hide path (I1)', () {
    test('structural: the snapshot record never enters the hideable '
        'population the judge/LRU/deterministic/agent walks share', () async {
      final (session, _) = await bugSession(repo);
      await saveWorkingSet(session, _notes);
      final entries = await session.getEntries();
      final path = classicTransform(await session.getBranch());
      final state = buildStructuredViewState(path);
      final visible = visibleStructuredPath(path, state);
      // The record exists on the branch…
      expect(
        entries.whereType<CustomRecord>().where(
          (r) => r.customType == workingSetRecordType,
        ),
        hasLength(1),
      );
      // …but never projects into the visible population (and thus never
      // into the judge ledger, the LRU candidate walk, the deterministic
      // fallback, or the agent-hide validation — all built over it).
      expect(visible.whereType<CustomRecord>(), isEmpty);
      final ledger = buildContextLedger(
        visiblePath: visible,
        seqs: RecordSeqIndex(entries),
      );
      expect(
        ledger.entries.where((e) => e.recordId.contains('working')),
        isEmpty,
      );
      // And no hide path can ever name it: appendHiddenRange with every
      // visible id still leaves the record unhidden for the request build.
      final ids = [for (final record in visible) record.id];
      await session.appendHiddenRange(recordIds: ids);
      await expectWorkingSetIntact(
        session,
        await session.buildContextMessages(),
      );
    });

    test(
      'judge hide: hiding EVERYTHING hideable keeps the working set',
      () async {
        final (session, state) = await bugSession(repo);
        await saveWorkingSet(session, _notes);
        final compactor = StructuredCompactor(
          session: session,
          state: state,
          window: 8000,
          settings: _settings,
          judge: hideEverythingJudge(),
          summarize: (request) async =>
              SummarizationResult.failure('no checkpoint in this test'),
          checkpointPrompt: 'P',
        );
        expect(await compactor.run(), isTrue);
        // Something was actually hidden (the test exercised the path).
        expect(
          (await session.getEntries()).whereType<HiddenRangeRecord>(),
          isNotEmpty,
        );
        await expectWorkingSetIntact(session, state.messages);
        expect(validateToolPairing(state.messages), isEmpty);
      },
    );

    test('deterministic fallback (dead judge) keeps the working set', () async {
      final (session, state) = await bugSession(repo);
      await saveWorkingSet(session, _notes);
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: (ledger, [token]) async => null,
        summarize: (request) async =>
            SummarizationResult.failure('no checkpoint in this test'),
        checkpointPrompt: 'P',
      );
      expect(await compactor.run(), isTrue);
      expect(
        (await session.getEntries()).whereType<HiddenRangeRecord>(),
        isNotEmpty,
        reason: 'the deterministic fallback must have engaged',
      );
      await expectWorkingSetIntact(session, state.messages);
    });

    test('checkpoint fold keeps the working set', () async {
      final (session, state) = await bugSession(repo);
      await saveWorkingSet(session, _notes);
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: (ledger, [token]) async => '[]',
        summarize: (request) async => SummarizationResult.success(
          'investigated the crash; wrote the fix; tests green',
        ),
        checkpointPrompt: 'CHECKPOINT INSTRUCTIONS',
      );
      expect(await compactor.run(), isTrue);
      expect(
        (await session.getEntries()).whereType<CompactCheckpointRecord>(),
        isNotEmpty,
      );
      await expectWorkingSetIntact(session, state.messages);
    });

    test(
      'emergency relief and the local trim valve keep the working set',
      () async {
        final (session, state) = await bugSession(repo);
        await saveWorkingSet(session, _notes);
        EmergencyRelief relief() => EmergencyRelief(
          session: session,
          state: state,
          window: 8000,
          settings: _settings,
        );
        // No structured boundary yet: the relief has no ledger to hide
        // from, so the MECHANICAL trim valve runs (live-context messages
        // dropped, no session record hidden) — the tier the audited
        // worker's guard would have hit.
        final trimmed = await relief().run();
        expect(trimmed.ok, isTrue);
        expect(trimmed.droppedMessages, greaterThan(0));
        expect(trimmed.hiddenRecords, 0);
        await expectWorkingSetIntact(session, state.messages);

        // A SECOND session WITH a boundary on the branch: the relief hides
        // groups (records behind markers) — the snapshot is just as
        // invisible to the hide tier.
        final (bounded, boundedState) = await bugSession(repo);
        await saveWorkingSet(bounded, _notes);
        final boundedEntries = await bounded.getEntries();
        await bounded.appendHiddenRange(
          recordIds: [boundedEntries[1].id, boundedEntries[2].id],
        );
        boundedState.messages = await bounded.buildContextMessages();
        final hidden = await EmergencyRelief(
          session: bounded,
          state: boundedState,
          // Under the transcript (≈3.1k tokens): the relief must hide.
          window: 4000,
          settings: _settings,
          keepRecent: const {'read': 0, 'exec': 0, 'other': 0},
        ).run();
        expect(hidden.ok, isTrue);
        expect(
          hidden.hiddenRecords,
          greaterThan(0),
          reason:
              'the hide tier ran (outcome: '
              'tok=${hidden.tokensBefore}->${hidden.tokensAfter} '
              'groups=${hidden.hiddenGroups} dropped=${hidden.droppedMessages} '
              'trim=${hidden.usedTrimValve})',
        );
        await expectWorkingSetIntact(bounded, boundedState.messages);
      },
    );

    test(
      'LRU re-hide after an expansion storm keeps the working set',
      () async {
        final (session, state) = await bugSession(repo);
        await saveWorkingSet(session, _notes);
        // The judge hides both big pairs first…
        final entries = await session.getEntries();
        await session.appendHiddenRange(
          recordIds: [entries[1].id, entries[2].id],
        );
        await session.appendHiddenRange(
          recordIds: [entries[5].id, entries[6].id],
        );
        // …the agent expands both (persisted like the loop does)…
        final agent = Agent(
          model: _model,
          streamFunction: (m, c, {cancelToken}) =>
              throw StateError('no LLM call expected'),
          toolRegistry: ToolRegistry(const []),
        );
        final controller = CompactExpandController(
          agent: agent,
          session: () => session,
        );
        Future<void> expand(int n, String target) async {
          final answer = await controller.tool.execute(
            {'target': target},
            null,
            null,
          );
          await session.appendMessage(
            _assistant(
              '',
              calls: [
                ToolCall(
                  id: 'ex$n',
                  name: compactExpandToolName,
                  arguments: {'target': target},
                ),
              ],
            ),
          );
          await session.appendMessage(
            _result('ex$n', compactExpandToolName, _textOf2(answer.content)),
          );
        }

        await expand(1, '3');
        await expand(2, '6');
        // …a fat pair + padding put the projection over the trigger…
        await session.appendMessage(
          _assistant(
            'fat',
            calls: [ToolCall(id: 'c-fat', name: 'read', arguments: {})],
          ),
        );
        await session.appendMessage(_result('c-fat', 'read', 'q' * 28000));
        for (var i = 0; i < 10; i++) {
          await session.appendMessage(_assistant('tail filler $i'));
        }
        final fatSeq = RecordSeqIndex(await session.getEntries()).seqOf(
          (await session.getEntries())
              .firstWhere(
                (r) =>
                    r is MessageRecord &&
                    r.message is AssistantMessage &&
                    (r.message as AssistantMessage).content.any(
                      (block) => block is ToolCall && block.id == 'c-fat',
                    ),
              )
              .id,
        );
        // …and the forced run re-hides the OLDEST expansion (LRU) while the
        // judged hide takes the fat pair.
        final compactor = StructuredCompactor(
          session: session,
          state: state,
          window: 8000,
          settings: _settings,
          protectLastN: 2,
          judge: (ledger, [token]) async => '["$fatSeq"]',
          summarize: (request) async =>
              SummarizationResult.failure('no checkpoint in this test'),
          checkpointPrompt: 'P',
        );
        expect(await compactor.run(force: true), isTrue);
        await expectWorkingSetIntact(session, state.messages);
        expect(validateToolPairing(state.messages), isEmpty);
        controller.dispose();
      },
    );

    test(
      'agent hide (compact_expand action=hide) keeps the working set',
      () async {
        final (session, state) = await bugSession(repo);
        await saveWorkingSet(session, _notes);
        final agent = Agent(
          model: _model,
          streamFunction: (m, c, {cancelToken}) =>
              throw StateError('no LLM call expected'),
          toolRegistry: ToolRegistry(const []),
        );
        final controller = CompactExpandController(
          agent: agent,
          session: () => session,
        );
        // Hide the visible assistant/tool prefix (the user turn at seq 2
        // stays — agent hide never touches real user turns).
        final answer = await controller.tool.execute(
          {'action': 'hide', 'target': '3-7'},
          null,
          null,
        );
        expect(_textOf2(answer.content), contains('hid records'));
        await expectWorkingSetIntact(
          session,
          await session.buildContextMessages(),
        );
        controller.dispose();
      },
    );
  });

  group('system channel through the agent loop (I2, AC2, AC3)', () {
    test('every request carries the block as a system-prompt suffix', () async {
      final (session, _) = await bugSession(repo, fillers: 0);
      await saveWorkingSet(session, _notes);
      final stream = FakeStreamFunction([textTurn('done')]);
      final agent = Agent(
        model: _model,
        systemPrompt: 'You are a coding agent.',
        streamFunction: stream.call,
        toolRegistry: ToolRegistry(const []),
        workingSetStore: SessionWorkingSetStore(session: () async => session),
      );
      await agent.prompt('go');
      final prompt = stream.contexts.single.systemPrompt!;
      expect(
        prompt,
        startsWith(
          'You are a coding agent.\n<working-set '
          'source="agent" updated="',
        ),
      );
      expect(prompt, endsWith('\n$_notes\n</working-set>'));
      // Never a message (I2): the text is in no user/assistant/tool message.
      final messages = stream.contexts.single.messages;
      expect(
        messages.where((m) => m.toJson().toString().contains(_notes)),
        isEmpty,
      );
      expect(validateToolPairing(messages), isEmpty);
    });

    test('no snapshot ⇒ the prompt object is untouched (I3)', () async {
      final (session, _) = await bugSession(repo, fillers: 0);
      final stream = FakeStreamFunction([textTurn('done')]);
      final agent = Agent(
        model: _model,
        systemPrompt: 'You are a coding agent.',
        streamFunction: stream.call,
        toolRegistry: ToolRegistry(const []),
        workingSetStore: SessionWorkingSetStore(session: () async => session),
      );
      await agent.prompt('go');
      expect(stream.contexts.single.systemPrompt, 'You are a coding agent.');
      expect(
        agent.state.systemPrompt,
        'You are a coding agent.',
        reason: 'the transcript prompt is never modified',
      );
    });

    test('no store ⇒ byte-identical request (the pre-#2423 shape)', () async {
      final (session, _) = await bugSession(repo, fillers: 0);
      await saveWorkingSet(session, _notes);
      final stream = FakeStreamFunction([textTurn('done')]);
      final agent = Agent(
        model: _model,
        systemPrompt: 'You are a coding agent.',
        streamFunction: stream.call,
        toolRegistry: ToolRegistry(const []),
      );
      await agent.prompt('go');
      expect(stream.contexts.single.systemPrompt, 'You are a coding agent.');
    });

    test('a write lands on the very next request; a clear removes it', () async {
      final (session, _) = await bugSession(repo, fillers: 0);
      final stream = FakeStreamFunction([
        textTurn('one'),
        textTurn('two'),
        textTurn('three'),
      ]);
      final agent = Agent(
        model: _model,
        systemPrompt: 'BASE',
        streamFunction: stream.call,
        toolRegistry: ToolRegistry(const []),
        workingSetStore: SessionWorkingSetStore(session: () async => session),
      );
      await agent.prompt('go');
      expect(stream.contexts[0].systemPrompt, 'BASE');
      await saveWorkingSet(session, 'first notes');
      await agent.prompt('go');
      expect(
        stream.contexts[1].systemPrompt,
        'BASE\n<working-set source="agent" updated="${clockOf(DateTime.utc(2026))}">\n'
        'first notes\n</working-set>',
      );
      await saveWorkingSet(session, '');
      await agent.prompt('go');
      expect(
        stream.contexts[2].systemPrompt,
        'BASE',
        reason: 'the clear event renders no block',
      );
    });

    test(
      'survives a hide and a process restart (a new agent + store)',
      () async {
        final (session, _) = await bugSession(repo);
        await saveWorkingSet(session, _notes);
        // "kill -9 + restart": the file is reopened, the resident view is
        // rebuilt from it, a NEW agent and store read the newest snapshot.
        final meta = await session.getMetadata();
        final reopened = await repo.open(meta);
        final entries = await reopened.getEntries();
        await reopened.appendHiddenRange(
          recordIds: [entries[1].id, entries[2].id],
        );
        final stream = FakeStreamFunction([textTurn('done')]);
        final agent = loopAgent(reopened, stream);
        await agent.prompt('continue');
        expect(
          stream.contexts.single.systemPrompt,
          endsWith('\n$_notes\n</working-set>'),
        );
      },
    );

    test('newest wins across the restart', () async {
      final (session, _) = await bugSession(repo, fillers: 0);
      await saveWorkingSet(session, 'old notes');
      await saveWorkingSet(session, 'newest notes');
      final stream = FakeStreamFunction([textTurn('done')]);
      final agent = loopAgent(session, stream);
      await agent.prompt('go');
      final prompt = stream.contexts.single.systemPrompt!;
      expect(prompt, contains('newest notes'));
      expect(prompt, isNot(contains('old notes')));
    });

    test(
      'a legacy goal_recitation renders until a working_set record exists',
      () async {
        final (session, _) = await bugSession(repo, fillers: 0);
        await session.appendCustomEntry(
          customType: goalRecitationRecordType,
          data: goalRecitationPayload('the legacy goal'),
        );
        final stream = FakeStreamFunction([textTurn('done'), textTurn('done')]);
        final agent = loopAgent(session, stream);
        await agent.prompt('go');
        expect(
          stream.contexts[0].systemPrompt,
          endsWith('\nthe legacy goal\n</working-set>'),
        );
        await saveWorkingSet(session, 'the real working set');
        await agent.prompt('go');
        expect(
          stream.contexts[1].systemPrompt,
          contains('the real working set'),
        );
        expect(stream.contexts[1].systemPrompt, isNot(contains('legacy goal')));
      },
    );
  });

  group('session survival (owner directive)', () {
    test(
      'writes are append-only: an old (large) session loads unchanged',
      () async {
        // An OLD session: pre-gh-210 shape — messages, structured folds, a
        // classic compaction record; no working-set records anywhere.
        final (session, state) = await bugSession(repo);
        final entries = await session.getEntries();
        await session.appendHiddenRange(
          recordIds: [entries[1].id, entries[2].id],
        );
        await session.appendCompaction(
          summary: 'old classic summary',
          firstKeptEntryId: entries[8].id,
          tokensBefore: 50000,
        );
        final path = (await session.getMetadata()).path;
        final oldBytes = (await fs.readBinaryFile(path)).getOrThrow();

        // The new build loads the old session and works on it: a forced
        // compaction pass (appends hide/checkpoint records) plus a saved
        // working set (appends the snapshot).
        final meta = await session.getMetadata();
        final compactor = StructuredCompactor(
          session: session,
          state: state,
          window: 8000,
          settings: _settings,
          judge: hideEverythingJudge(),
          summarize: (request) async =>
              SummarizationResult.success('fresh checkpoint text'),
          checkpointPrompt: 'P',
        );
        await compactor.run(force: true);
        await saveWorkingSet(session, _notes);
        final newBytes = (await fs.readBinaryFile(meta.path)).getOrThrow();

        // Append-only: every OLD byte is untouched — the new records are a
        // strict tail extension of the file.
        expect(newBytes.length, greaterThan(oldBytes.length));
        expect(
          newBytes.sublist(0, oldBytes.length),
          equals(oldBytes),
          reason: 'gh-210/gh-2423 writes must never rewrite session bytes',
        );

        // The old session still loads whole: every original record is
        // present and parses.
        final reloaded = Session(await JsonlSessionStorage.open(fs, meta.path));
        final reloadedEntries = await reloaded.getEntries();
        expect(reloadedEntries.length, greaterThan(entries.length));
        for (final entry in entries) {
          expect(
            reloadedEntries.any(
              (e) => e.id == entry.id && e.type == entry.type,
            ),
            isTrue,
            reason: 'original record ${entry.id} (${entry.type}) must survive',
          );
        }
        // And the request build reads the additive record.
        final snapshot = await reloaded.workingSetSnapshot();
        expect(snapshot!.text, _notes);
        final messages = await reloaded.buildContextMessages();
        expect(_isFilesBlock(messages.last), isTrue);
      },
    );
  });
}

/// Tool results arrive as content blocks; flatten for assertions.
String _textOf2(List<ContentBlock> content) =>
    content.whereType<TextContent>().map((block) => block.text).join('\n');
