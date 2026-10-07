// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Issue #1379 — the structured compaction second tier: agent-initiated
/// hide, LRU re-hide after expansion, per-segment pins. Every acceptance
/// row of the issue gets a test; the property test interleaves all three
/// and holds the losslessness invariant.

library;

import 'dart:convert' show jsonEncode;
import 'dart:math';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:flutter_agent_harness/src/compaction/structured/ledger.dart';
import 'package:flutter_agent_harness/src/compaction/structured/markers.dart';
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

String _textOf(Message m) => switch (m) {
  AssistantMessage(:final content) => _flat(content),
  ToolResultMessage(:final content) => _flat(content),
  UserMessage(:final content) => _flat(content),
  _ => '',
};

String _flat(Object? content) => content is String
    ? content
    : (content as List<Object>)
          .whereType<TextContent>()
          .map((block) => block.text)
          .join('\n');

Future<StructuredViewState> _viewOf(Session session) async {
  final path = classicTransform(await session.getBranch());
  return buildStructuredViewState(path);
}

/// A bug-fix-shaped history: real user ask, big read pair (records
/// 3-4), analysis, big bash pair (records 6-7), then [fillers] trailing
/// assistant notes.
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
  await session.appendMessage(_assistant('found token-expiry bug'));
  await session.appendMessage(
    _assistant(
      'running',
      calls: [ToolCall(id: 'c2', name: 'bash', arguments: {})],
    ),
  );
  await session.appendMessage(_result('c2', 'bash', 'y' * 12000));
  for (var i = 0; i < fillers; i++) {
    await session.appendMessage(_assistant('filler analysis $i'));
  }
  final messages = await session.buildContextMessages();
  return (session, AgentState(model: _model, messages: messages));
}

/// A controller bound to [session] with a tiny page size so giant
/// segments page.
CompactExpandController controllerFor(Session session, Agent agent) {
  final controller = CompactExpandController(
    agent: agent,
    session: () => session,
  );
  return controller;
}

Agent agentFor() => Agent(
  model: _model,
  streamFunction: (m, c, {cancelToken}) =>
      throw StateError('no LLM call expected'),
  toolRegistry: ToolRegistry(const []),
);

Future<String> callTool(
  CompactExpandController controller,
  Map<String, Object?> args,
) async {
  final result = await controller.tool.execute(args, null, null);
  return _flat(result.content);
}

/// Expands like the loop would: the tool runs, then the agent persists
/// its call + the delivered result (the LRU tier re-hides exactly these
/// artifacts, so the test replays the same persistence contract).
Future<String> expandViaLoop(
  Session session,
  CompactExpandController controller,
  int callNumber,
  String target,
) async {
  final answer = await callTool(controller, {'target': target});
  expect(answer, contains('[expand $target'), reason: answer);
  await session.appendMessage(
    _assistant(
      '',
      calls: [
        ToolCall(
          id: 'ex$callNumber',
          name: compactExpandToolName,
          arguments: {'target': target},
        ),
      ],
    ),
  );
  await session.appendMessage(
    _result('ex$callNumber', compactExpandToolName, answer),
  );
  return answer;
}

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  group('AC1 — agent-initiated hide', () {
    test('hides a whole pair group mid-turn and refreshes state', () async {
      final (session, state) = await bugSession(repo);
      final agent = agentFor();
      final controller = controllerFor(session, agent);
      // Hide the read pair by its carrier (record 3): the group snaps
      // outward to carrier + result.
      final answer = await callTool(controller, {
        'action': 'hide',
        'target': '3',
      });
      expect(answer, contains('hid records 3-4'));
      // Session state: exactly one hidden_range naming both ids.
      final view = await _viewOf(session);
      expect(view.hiddenRecordIds, hasLength(2));
      // State refresh: the very next wire renders markers, not content.
      final wire = agent.state.messages;
      final markers = [
        for (final message in wire.whereType<UserMessage>())
          if ((message.content as String).contains(':hidden'))
            message.content as String,
      ];
      expect(markers, hasLength(2));
    });

    test('unknown id answers with the valid range', () async {
      final (session, _) = await bugSession(repo);
      final controller = controllerFor(session, agentFor());
      final answer = await callTool(controller, {
        'action': 'hide',
        'target': '999',
      });
      expect(answer, contains('no record 999'));
      expect(answer, contains('valid ids'));
    });

    test('real user turns are rejected, never hidden', () async {
      final (session, _) = await bugSession(repo);
      final controller = controllerFor(session, agentFor());
      final answer = await callTool(controller, {
        'action': 'hide',
        'target': '2',
      });
      expect(answer, contains('real user turns'));
      expect((await _viewOf(session)).hiddenRecordIds, isEmpty);
    });

    test('the protected tail is rejected with the reason', () async {
      final (session, _) = await bugSession(repo);
      final controller = controllerFor(session, agentFor());
      // protectLastN=8: records 12-19 are the tail; record 14 is a
      // recent filler the hide must refuse to fold.
      final answer = await callTool(controller, {
        'action': 'hide',
        'target': '14',
      });
      expect(answer, contains('protected recent tail'));
    });

    test('already-hidden targets answer honestly, append nothing', () async {
      final (session, _) = await bugSession(repo);
      await session.appendHiddenRange(
        recordIds: [
          (await session.getEntries())[1].id,
          (await session.getEntries())[2].id,
        ],
      );
      final controller = controllerFor(session, agentFor());
      final answer = await callTool(controller, {
        'action': 'hide',
        'target': '3-4',
      });
      expect(answer, contains('already hidden'));
    });

    test('unknown action name is a structured error', () async {
      final (session, _) = await bugSession(repo);
      final controller = controllerFor(session, agentFor());
      final answer = await callTool(controller, {
        'action': 'obliterate',
        'target': '3',
      });
      expect(answer, contains('unknown action'));
    });
  });

  group('AC2 — LRU re-hide after expansion', () {
    test('pressure evicts the oldest expansion, keeps the newest, segments '
        'stay expandable', () async {
      final (session, state) = await bugSession(repo);
      // Judge hides the whole read pair (records 3-4).
      final readPair = [
        (await session.getEntries())[1].id,
        (await session.getEntries())[2].id,
      ];
      final bashPair = [
        (await session.getEntries())[4].id,
        (await session.getEntries())[5].id,
      ];
      await session.appendHiddenRange(recordIds: readPair);
      await session.appendHiddenRange(recordIds: bashPair);
      final agent = agentFor();
      final controller = controllerFor(session, agent);
      // Expand storm: read pair first, bash pair second (newest).
      await expandViaLoop(session, controller, 1, '3');
      await expandViaLoop(session, controller, 2, '6');
      final afterExpand = await _viewOf(session);
      // Both expand artifacts are visible pairs on the branch.
      final branch = await session.getBranch();
      final expandCarriers = [
        for (final record in branch)
          if (record is MessageRecord &&
              record.message is AssistantMessage &&
              (record.message as AssistantMessage).content.any(
                (block) =>
                    block is ToolCall && block.name == compactExpandToolName,
              ))
            record.id,
      ];
      expect(expandCarriers, hasLength(2));
      final pairs = <String, Set<String>>{};
      final ledger = buildContextLedger(
        visiblePath: visibleStructuredPath(branch, afterExpand),
        seqs: RecordSeqIndex(await session.getEntries()),
      );
      for (final carrier in expandCarriers) {
        pairs[carrier] = ledger.groupOf(carrier);
      }
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        protectLastN: 2,
        judge: (ledgerText) async => '[]',
        summarize: (request) async =>
            SummarizationResult.failure('no checkpoint in this test'),
        checkpointPrompt: 'P',
      );
      final fit = await compactor.run(force: true);
      expect(fit, isTrue);
      final view1 = await _viewOf(session);
      final oldest = pairs[expandCarriers.first]!;
      final newest = pairs[expandCarriers.last]!;
      // Oldest expansion re-hidden; newest kept (AC2).
      expect(
        view1.hiddenRecordIds.containsAll(oldest),
        isTrue,
        reason: 'oldest expand pair must re-hide',
      );
      expect(
        newest.any(view1.hiddenRecordIds.contains),
        isFalse,
        reason: 'newest expand pair must stay visible',
      );
      // Lossless (#148 AC2): the ORIGINAL segments are still
      // hidden-but-expandable, and discovery still lists them.
      expect(view1.hiddenRecordIds.containsAll(readPair), isTrue);
      expect(view1.hiddenRecordIds.containsAll(bashPair), isTrue);
      final answer = await callTool(controller, {'target': '3'});
      expect(answer, contains('[expand 3'));
    });
  });

  group('AC3 — per-segment pins', () {
    test('judge picks on pinned segments silently fall through', () async {
      final (session, state) = await bugSession(repo);
      final agent = agentFor();
      final controller = controllerFor(session, agent);
      final answer = await callTool(controller, {
        'action': 'pin',
        'target': '3',
      });
      expect(answer, contains('pinned records 3'));
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        protectLastN: 2,
        judge: (ledgerText) async => '["3"]',
        summarize: (request) async =>
            SummarizationResult.failure('no checkpoint in this test'),
        checkpointPrompt: 'P',
      );
      await compactor.run(force: true);
      final view = await _viewOf(session);
      final pinnedId = (await session.getEntries())[1].id;
      expect(view.hiddenRecordIds.contains(pinnedId), isFalse);
    });

    test('agent hide on a pinned segment is a structured error', () async {
      final (session, _) = await bugSession(repo);
      final controller = controllerFor(session, agentFor());
      await callTool(controller, {'action': 'pin', 'target': '3'});
      final answer = await callTool(controller, {
        'action': 'hide',
        'target': '3',
      });
      expect(answer, contains('pinned'));
      expect((await _viewOf(session)).hiddenRecordIds, isEmpty);
    });

    test('unpin releases the segment', () async {
      final (session, _) = await bugSession(repo);
      final controller = controllerFor(session, agentFor());
      await callTool(controller, {'action': 'pin', 'target': '3'});
      await callTool(controller, {'action': 'unpin', 'target': '3'});
      final answer = await callTool(controller, {
        'action': 'hide',
        'target': '3',
      });
      expect(answer, contains('hid records'));
    });

    test('a checkpoint never swallows a pinned segment', () async {
      final (session, state) = await bugSession(repo);
      final agent = agentFor();
      final controller = controllerFor(session, agent);
      await callTool(controller, {'action': 'pin', 'target': '4'});
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        protectLastN: 2,
        judge: (ledgerText) async => '[]',
        summarize: (request) async => SummarizationResult.success(
          'Earlier work: a login crash investigation across a read pair '
          'and a bash pair. Both tool outputs were consumed.',
        ),
        checkpointPrompt: 'P',
      );
      await compactor.run(force: true);
      final pinnedId = (await session.getEntries())[2].id;
      for (final record in await session.getBranch()) {
        if (record is CompactCheckpointRecord) {
          expect(
            record.coversRecordIds,
            isNot(contains(pinnedId)),
            reason: 'no checkpoint may swallow a pinned record',
          );
        }
      }
    });

    test('a deep pin cannot starve checkpointing (foldable walk)', () async {
      final (session, state) = await bugSession(repo);
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        protectLastN: 2,
        judge: (ledgerText) async => '[]',
        summarize: (request) async => SummarizationResult.success(
          'Earlier work: a login crash investigation across a read pair '
          'and a bash pair. Both tool outputs were consumed.',
        ),
        checkpointPrompt: 'P',
      );
      // Pin the EARLIEST hideable record: under the old cut-clamp the
      // pin sat inside every candidate range and clamped the cut to
      // zero — no checkpoint ever formed. The foldable walk drops the
      // pin out of the candidate set BEFORE the keep-recent walk, so
      // checkpointing still makes progress behind it.
      await callTool(controllerFor(session, agentFor()), {
        'action': 'pin',
        'target': '4',
      });
      await compactor.run(force: true);
      final pinnedId = (await session.getEntries())[2].id;
      final checkpoints = [
        for (final record in await session.getBranch())
          if (record is CompactCheckpointRecord) record,
      ];
      expect(checkpoints, isNotEmpty, reason: 'deep pin must not starve');
      for (final record in checkpoints) {
        expect(record.coversRecordIds, isNotEmpty);
        expect(
          record.coversRecordIds,
          isNot(contains(pinnedId)),
          reason: 'progress without swallowing the pin',
        );
      }
    });

    test('pins survive session reload', () async {
      final (session, _) = await bugSession(repo);
      final controller = controllerFor(session, agentFor());
      await callTool(controller, {'action': 'pin', 'target': '4'});
      await callTool(controller, {'action': 'unpin', 'target': '3'});
      final metadata = await session.getMetadata();
      final reopened = await repo.open(metadata);
      final view = await _viewOf(reopened);
      expect(
        view.pinnedRecordIds,
        contains((await session.getEntries())[2].id),
      );
      expect(
        view.pinnedRecordIds,
        isNot(contains((await session.getEntries())[1].id)),
      );
    });
  });

  group('AC4 — marker budget (tier 2 variants)', () {
    test('pinned markers stay inside the 12-token pin', () {
      for (final kind in [
        markerKinds.user,
        markerKinds.notice,
        markerKinds.assistant,
        markerKinds.toolResult,
        markerKinds.legacyCheckpoint,
        markerKinds.branchSummary,
      ]) {
        for (final tokens in [0, 1, 999, 4231, 9999, 1234567]) {
          final marker = hiddenMarker(
            seq: 1482003,
            kind: kind,
            tokens: tokens,
            pinned: true,
          );
          expect(
            estimateTokens(UserMessage.text(marker)),
            lessThanOrEqualTo(12),
            reason: 'marker $marker must stay within the 12-token pin',
          );
        }
      }
    });
  });

  group('AC5 — property: pin/hide/LRU interleavings stay lossless', () {
    test(
      'random interleavings keep the wire valid and the file whole',
      () async {
        final random = Random(7);
        for (var trial = 0; trial < 12; trial++) {
          final (session, state) = await bugSession(repo);
          final agent = agentFor();
          final controller = controllerFor(session, agent);
          final entryCountAtStart = (await session.getEntries()).length;
          for (var step = 0; step < 10; step++) {
            final branch = await session.getBranch();
            final seqs = RecordSeqIndex(await session.getEntries());
            final view = await _viewOf(session);
            final visibleSeqs = [
              for (final record in visibleStructuredPath(branch, view))
                seqs.seqOf(record.id)!,
            ];
            switch (random.nextInt(6)) {
              case 0: // judge hide pass
                final picks = [
                  for (var i = 0; i < 2; i++)
                    visibleSeqs[random.nextInt(visibleSeqs.length)],
                ];
                final compactor = StructuredCompactor(
                  session: session,
                  state: state,
                  window: 8000,
                  settings: _settings,
                  protectLastN: 1,
                  judge: (ledgerText) async => jsonEncode(picks),
                  summarize: (request) async =>
                      SummarizationResult.failure('no checkpoint'),
                  checkpointPrompt: 'P',
                );
                await compactor.run(force: true);
              case 1: // expand a random hidden segment
                final hidden = [
                  for (final record in branch)
                    if (view.hiddenRecordIds.contains(record.id))
                      seqs.seqOf(record.id)!,
                ];
                if (hidden.isEmpty) break;
                await callTool(controller, {
                  'target': '${hidden[random.nextInt(hidden.length)]}',
                });
              case 2: // pin a random visible segment
                await callTool(controller, {
                  'action': 'pin',
                  'target':
                      '${visibleSeqs[random.nextInt(visibleSeqs.length)]}',
                });
              case 3: // unpin a random segment
                await callTool(controller, {
                  'action': 'unpin',
                  'target': '${2 + random.nextInt(seqs.entries.length)}',
                });
              case 4: // agent hide a random visible segment
                await callTool(controller, {
                  'action': 'hide',
                  'target':
                      '${visibleSeqs[random.nextInt(visibleSeqs.length)]}',
                });
              case 5: // append filler
                await session.appendMessage(_assistant('more work $step'));
            }
            await _assertInvariants(
              repo,
              session,
              entryCountAtStart,
              'trial $trial step $step',
            );
          }
        }
      },
    );
  });
}

/// The losslessness invariant (issue #148 AC2, #1379 AC5):
///
/// 1. the session file only ever grows;
/// 2. every id referenced by structured state exists in the file;
/// 3. the projected wire is tool-pair-safe — every tool_result on the
///    wire answers a tool_use on the wire, and every live tool_use has
///    its answer (orphan pairs downgrade to user markers);
/// 4. the projection is deterministic — a fresh open projects to the
///    same wire shape.
Future<void> _assertInvariants(
  JsonlSessionRepo repo,
  Session session,
  int entryCountAtStart,
  String where,
) async {
  final entries = await session.getEntries();
  final branch = await session.getBranch();
  final ids = {for (final record in entries) record.id};
  // 1. append-only.
  expect(
    entries.length,
    greaterThanOrEqualTo(entryCountAtStart),
    reason: where,
  );
  // 2. referenced ids exist.
  for (final record in branch) {
    if (record is HiddenRangeRecord) {
      for (final id in record.recordIds) {
        expect(ids, contains(id), reason: '$where: hidden id $id');
      }
    }
    if (record is SegmentPinRecord) {
      for (final id in record.recordIds) {
        expect(ids, contains(id), reason: '$where: pinned id $id');
      }
    }
    if (record is CompactCheckpointRecord) {
      for (final id in record.coversRecordIds) {
        expect(ids, contains(id), reason: '$where: covered id $id');
      }
    }
  }
  // 3. wire pairing.
  final wire = await session.buildContextMessages();
  final callIds = <String>{};
  for (final message in wire.whereType<AssistantMessage>()) {
    for (final block in message.content) {
      if (block is ToolCall) callIds.add(block.id);
    }
  }
  final resultIds = <String>{};
  for (final message in wire.whereType<ToolResultMessage>()) {
    expect(
      callIds,
      contains(message.toolCallId),
      reason: '$where: result ${message.toolCallId} has no live call',
    );
    resultIds.add(message.toolCallId);
  }
  for (final id in callIds) {
    expect(
      resultIds,
      contains(id),
      reason: '$where: call $id has no result on the wire',
    );
  }
  // 4. determinism across a fresh open of the same file.
  final metadata = await session.getMetadata();
  final reopened = await repo.open(metadata);
  final wire2 = await reopened.buildContextMessages();
  expect(wire2.length, wire.length, reason: where);
  for (var i = 0; i < wire.length; i++) {
    expect(_textOf(wire2[i]), _textOf(wire[i]), reason: where);
  }
}
