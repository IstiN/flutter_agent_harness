// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-210 — the working set at the context tail: the level-0 projection,
/// the hide-protection contract (the slot survives EVERY hide path —
/// judge, deterministic fallback, LRU re-hide, agent hide, checkpoint
/// fold), the windowed-scan fallback, and the session-survival fixture
/// (append-only writes; an old session loads unchanged).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:flutter_agent_harness/src/compaction/structured/ledger.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart';
import 'package:test/test.dart';

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

const _goal = 'fix the login crash, then update the changelog';

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

bool _isWorkingSetBlock(Message m) =>
    _textOf(m).startsWith('<system-notice>\nworking set');

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

Future<void> recite(Session session, String goal) => session.appendCustomEntry(
  customType: goalRecitationRecordType,
  data: goalRecitationPayload(goal),
);

/// A judge that hides EVERY seq it can see (exempt/protected-tail picks
/// fall out in validation) — the strongest judge a run can face.
Future<String> Function(String, [CancelToken?]) hideEverythingJudge() =>
    (ledgerText, [cancelToken]) async {
      final ids = RegExp(
        r'\[(\d+)\]',
      ).allMatches(ledgerText).map((m) => m.group(1)!).toSet();
      return '[${ids.join(',')}]';
    };

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  group('level-0 projection', () {
    test(
      'a recitation renders as the tail block without a compaction',
      () async {
        final (session, _) = await bugSession(repo);
        await recite(session, _goal);
        final messages = await session.buildContextMessages();
        expect(_isWorkingSetBlock(messages.last), isTrue);
        expect(_textOf(messages.last), contains('goal: $_goal'));
        // No compaction boundary → no files section.
        expect(
          _textOf(messages.last),
          isNot(contains('recently touched files')),
        );
        // The obligations block (when present) stays ahead of the tail block.
        expect(
          messages.where((m) => _textOf(m).startsWith('<system-notice>')),
          hasLength(1),
        );
      },
    );

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
        expect(_isWorkingSetBlock(messages.last), isTrue);
        final block = _textOf(messages.last);
        expect(block, contains('recently touched files'));
        expect(block, contains('- lib/auth.dart'));
        expect(block, contains('re-read on demand'));
      },
    );

    test(
      'a session with no recitation and no compaction renders no block',
      () async {
        final (session, _) = await bugSession(repo);
        final messages = await session.buildContextMessages();
        // The projection is exactly the pre-gh-210 shape: the last message
        // is the last record's own message.
        expect(_isWorkingSetBlock(messages.last), isFalse);
        final entries = await session.getEntries();
        expect(messages.last, (entries.last as MessageRecord).message);
      },
    );

    test('a cleared slot stops rendering the goal', () async {
      final (session, _) = await bugSession(repo);
      await recite(session, _goal);
      await recite(session, '');
      final messages = await session.buildContextMessages();
      expect(_isWorkingSetBlock(messages.last), isFalse);
    });

    test(
      'the obligations block stays ahead of the working set at the tail',
      () async {
        final (session, _) = await bugSession(repo);
        // Seed BOTH level-0 blocks: an obligations snapshot, then the slot.
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
        await recite(session, _goal);
        final messages = await session.buildContextMessages();
        final notices = messages
            .map(_textOf)
            .where((t) => t.startsWith('<system-notice>'))
            .toList();
        expect(notices, hasLength(2));
        expect(notices.first, contains('obligations'));
        expect(notices.last, contains('goal: $_goal'));
        expect(_isWorkingSetBlock(messages.last), isTrue);
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
      expect(_isWorkingSetBlock(messages.last), isTrue);
      expect(_textOf(messages.last), contains('- lib/auth.dart'));
    });

    test('WINDOWED: a recitation below the resident tail still renders '
        '(raw-scan fallback, the #488 class)', () async {
      final (session, _) = await bugSession(repo);
      await recite(session, _goal);
      for (var i = 0; i < 650; i++) {
        await session.appendMessage(UserMessage.text('filler $i'));
      }
      final meta = await session.getMetadata();
      final windowed = await repo.open(meta, windowed: true);
      // Sanity: the resident view has no recitation at all.
      expect(latestGoalRecitationIn(await windowed.getEntries()), isNull);
      final messages = await windowed.buildContextMessages();
      expect(_isWorkingSetBlock(messages.last), isTrue);
      expect(_textOf(messages.last), contains('goal: $_goal'));
      expect(validateToolPairing(messages), isEmpty);
    });
  });

  group('hide protection — the slot survives every hide path', () {
    test('structural: the recitation record never enters the hideable '
        'population the judge/LRU/deterministic/agent walks share', () async {
      final (session, _) = await bugSession(repo);
      await recite(session, _goal);
      final entries = await session.getEntries();
      final path = classicTransform(await session.getBranch());
      final state = buildStructuredViewState(path);
      final visible = visibleStructuredPath(path, state);
      // The record exists on the branch…
      expect(
        entries.whereType<CustomRecord>().where(
          (r) => r.customType == goalRecitationRecordType,
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
        ledger.entries.where((e) => e.recordId.contains('recitation')),
        isEmpty,
      );
      // And no hide path can ever name it: appendHiddenRange with every
      // visible id still leaves the record unhidden in the projection.
      final ids = [for (final record in visible) record.id];
      await session.appendHiddenRange(recordIds: ids);
      final messages = await session.buildContextMessages();
      expect(_isWorkingSetBlock(messages.last), isTrue);
    });

    test(
      'judge hide: hiding EVERYTHING hideable keeps the goal at the tail',
      () async {
        final (session, state) = await bugSession(repo);
        await recite(session, _goal);
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
        // The slot survives at the tail, goal intact.
        expect(_isWorkingSetBlock(state.messages.last), isTrue);
        expect(_textOf(state.messages.last), contains('goal: $_goal'));
        expect(validateToolPairing(state.messages), isEmpty);
      },
    );

    test(
      'deterministic fallback (dead judge) keeps the goal at the tail',
      () async {
        final (session, state) = await bugSession(repo);
        await recite(session, _goal);
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
        expect(_isWorkingSetBlock(state.messages.last), isTrue);
        expect(_textOf(state.messages.last), contains('goal: $_goal'));
      },
    );

    test('checkpoint fold keeps the goal at the tail', () async {
      final (session, state) = await bugSession(repo);
      await recite(session, _goal);
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
      expect(_isWorkingSetBlock(state.messages.last), isTrue);
      expect(_textOf(state.messages.last), contains('goal: $_goal'));
    });

    test(
      'LRU re-hide after an expansion storm keeps the goal at the tail',
      () async {
        final (session, state) = await bugSession(repo);
        await recite(session, _goal);
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
        // The slot survives at the tail, goal intact.
        expect(_isWorkingSetBlock(state.messages.last), isTrue);
        expect(_textOf(state.messages.last), contains('goal: $_goal'));
        expect(validateToolPairing(state.messages), isEmpty);
        controller.dispose();
      },
    );

    test(
      'agent hide (compact_expand action=hide) keeps the goal at the tail',
      () async {
        final (session, state) = await bugSession(repo);
        await recite(session, _goal);
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
        final messages = await session.buildContextMessages();
        expect(_isWorkingSetBlock(messages.last), isTrue);
        expect(_textOf(messages.last), contains('goal: $_goal'));
        controller.dispose();
      },
    );
  });

  group('session survival (owner directive)', () {
    test(
      'writes are append-only: an old (large) session loads unchanged',
      () async {
        // An OLD session: pre-gh-210 shape — messages, structured folds, a
        // classic compaction record; no goal_recitation records anywhere.
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
        // compaction pass (appends hide/checkpoint records) plus a recited
        // goal (appends the slot snapshot).
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
        await recite(session, _goal);
        final newBytes = (await fs.readBinaryFile(meta.path)).getOrThrow();

        // Append-only: every OLD byte is untouched — the new records are a
        // strict tail extension of the file.
        expect(newBytes.length, greaterThan(oldBytes.length));
        expect(
          newBytes.sublist(0, oldBytes.length),
          equals(oldBytes),
          reason: 'gh-210 writes must never rewrite or replace session bytes',
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
        // And the new tail block renders from the additive records only.
        final messages = await reloaded.buildContextMessages();
        expect(_isWorkingSetBlock(messages.last), isTrue);
        expect(_textOf(messages.last), contains('goal: $_goal'));
      },
    );
  });
}

/// Tool results arrive as content blocks; flatten for assertions.
String _textOf2(List<ContentBlock> content) =>
    content.whereType<TextContent>().map((block) => block.text).join('\n');
