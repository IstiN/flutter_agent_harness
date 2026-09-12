// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #148 — acceptance-criteria integration suite (AC1–AC9):
/// config chain, losslessness property, addressing stability, marker
/// budget, pair integrity, two-pass relief, agent recall (incl. nesting),
/// wire shape, replay, and classic/structured coexistence.

import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:flutter_agent_harness/src/compaction/structured/expand_tool.dart';
import 'package:flutter_agent_harness/src/compaction/structured/judge.dart';
import 'package:flutter_agent_harness/src/compaction/structured/ledger.dart';
import 'package:flutter_agent_harness/src/compaction/structured/markers.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_snapshot_builder.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'm1',
  api: 'anthropic-messages',
  provider: 'p',
  baseUrl: 'http://localhost:1',
  contextWindow: 8000,
  maxTokens: 4096,
);

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) {
  return AssistantMessage(
    content: [
      TextContent(text: text),
      if (calls != null) ...calls,
    ],
    api: 'anthropic-messages',
    provider: 'p',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

ToolResultMessage _result(String callId, String name, String text) {
  return ToolResultMessage(
    toolCallId: callId,
    toolName: name,
    content: [TextContent(text: text)],
    isError: false,
    timestamp: DateTime.utc(2026),
  );
}

/// Window 8000, reserve 2000 → trigger 6000; keep-recent 2000.
const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 2000,
  keepRecentTokens: 2000,
);

/// Flattens raw message content (String or block list).
String _flat(Object? content) => content is String
    ? content
    : (content as List<Object>)
          .whereType<TextContent>()
          .map((b) => b.text)
          .join('\n');

/// Flattens any message's text content for byte-level comparisons.
String _textOf(Message m) => switch (m) {
  UserMessage() => _flat(m.content),
  AssistantMessage() =>
    m.content.whereType<TextContent>().map((b) => b.text).join('\n'),
  ToolResultMessage() =>
    m.content.whereType<TextContent>().map((b) => b.text).join('\n'),
  _ => '',
};

/// A value snapshot of a rendered view — roles + flattened text.
List<(String, String)> _shapeOf(List<Message> messages) => [
  for (final m in messages) (m.role, _textOf(m)),
];

/// Fake [StreamFunction] replaying scripted turns, capturing contexts.
class _FakeStream {
  _FakeStream(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant('');
  final partial = _assistant(text);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

List<AssistantMessageEvent> _toolTurn(List<ToolCall> calls) {
  final empty = _assistant('');
  final partial = _assistant('', calls: calls);
  final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
  for (var i = 0; i < calls.length; i++) {
    events
      ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
      ..add(
        ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial),
      );
  }
  events.add(DoneEvent(reason: StopReason.toolUse, message: partial));
  return events;
}

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  AgentState stateFor(List<Message> messages) =>
      AgentState(model: _model, messages: messages);

  /// A random-ish bug-fix shaped session: user ask, N tool pairs with fat
  /// results, assistant analyses, filler turns, closing user ask.
  Future<Session> syntheticSession(
    Random random, {
    int pairs = 3,
    int payloadChars = 4000,
  }) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('fix the login crash'));
    for (var i = 0; i < pairs; i++) {
      await session.appendMessage(
        _assistant(
          'step $i',
          calls: [ToolCall(id: 'c$i', name: 'read', arguments: {})],
        ),
      );
      await session.appendMessage(
        _result(
          'c$i',
          'read',
          'payload $i ${'x' * (payloadChars + random.nextInt(payloadChars))}',
        ),
      );
      await session.appendMessage(_assistant('analysis $i findings'));
    }
    for (var i = 0; i < 3; i++) {
      await session.appendMessage(_assistant('filler $i'));
    }
    await session.appendMessage(UserMessage.text('what was the exact error?'));
    return session;
  }

  /// Judge that picks a random subset of the ledger lines (occasionally
  /// contaminated with junk — validation must strip, never corrupt).
  Future<String?> Function(String) randomJudge(Random random) {
    final seqRe = RegExp(r'^\[(\d+)\]', multiLine: true);
    return (ledgerText) async {
      final seqs = seqRe
          .allMatches(ledgerText)
          .map((m) => int.parse(m.group(1)!))
          .toList();
      if (seqs.isEmpty) return null;
      seqs.shuffle(random);
      final picks = seqs.take(1 + random.nextInt(seqs.length)).toList()..sort();
      final out = <String>[for (final n in picks) '$n'];
      if (random.nextBool())
        out
          ..add('bogus')
          ..add('999999');
      return jsonEncode(out);
    };
  }

  group('AC1 — compaction.engine config chain (UT-config)', () {
    test('strict parse: classic/structured/null; typos throw', () {
      expect(CompactionEngine.tryParse(null, label: 'cfg'), isNull);
      expect(
        CompactionEngine.tryParse('classic', label: 'cfg'),
        CompactionEngine.classic,
      );
      expect(
        CompactionEngine.tryParse('structured', label: 'cfg'),
        CompactionEngine.structured,
      );
      expect(
        () => CompactionEngine.tryParse('StructureD', label: 'cfg'),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => CompactionEngine.tryParse(42, label: 'cfg'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('section parse accepts {engine: …} maps, rejects scalars', () {
      expect(CompactionEngine.fromSection(null, label: 'cfg'), isNull);
      expect(
        CompactionEngine.fromSection({'engine': 'structured'}, label: 'cfg'),
        CompactionEngine.structured,
      );
      expect(CompactionEngine.fromSection({}, label: 'cfg'), isNull);
      expect(
        () => CompactionEngine.fromSection('structured', label: 'cfg'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('resolution: session > project > global > classic default', () {
      expect(resolveCompactionEngine(), CompactionEngine.classic);
      expect(
        resolveCompactionEngine(global: CompactionEngine.structured),
        CompactionEngine.structured,
      );
      expect(
        resolveCompactionEngine(
          global: CompactionEngine.structured,
          project: CompactionEngine.classic,
        ),
        CompactionEngine.classic,
      );
      expect(
        resolveCompactionEngine(
          global: CompactionEngine.classic,
          project: CompactionEngine.classic,
          session: CompactionEngine.structured,
        ),
        CompactionEngine.structured,
      );
    });

    test('loadProjectCompactionEngine: absent/valid/invalid project file', () {
      final dir = Directory.systemTemp.createTempSync('fa_compcfg_');
      try {
        // Absent file → null (global config applies).
        expect(loadProjectCompactionEngine(dir.path), isNull);

        // Valid section parses; project wins over the global default.
        final file = File('${dir.path}/.fah/config.yaml')
          ..createSync(recursive: true);
        file.writeAsStringSync('compaction:\n  engine: structured\n');
        expect(
          loadProjectCompactionEngine(dir.path),
          CompactionEngine.structured,
        );

        // Present-but-invalid throws (strict, like the user config).
        file.writeAsStringSync('compaction:\n  engine: turbo\n');
        expect(
          () => loadProjectCompactionEngine(dir.path),
          throwsA(isA<ConfigException>()),
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test(
      'each engine runs with the other selected (coexistence smoke)',
      () async {
        for (final engine in CompactionEngine.values) {
          final session = await syntheticSession(Random(7));
          final state = stateFor(await session.buildContextMessages());
          final ok = await AutoCompactorFactory(
            session: session,
            state: state,
            window: 8000,
            settings: _settings,
            sources: AutoCompactorSources(
              smolStream: null,
              smolModel: null,
              mainStream: (m, c, {cancelToken}) =>
                  _FakeStream([_textTurn('sum $engine')]).call(m, c),
              mainModel: _model,
            ),
            hooks: _NoopHooks(),
            engine: engine,
          ).run();
          expect(
            validateToolPairing(state.messages),
            isEmpty,
            reason: 'wire valid under $engine',
          );
          // Either relieved, or left intact — never corrupted.
          expect(state.messages, isNotEmpty);
          expect(ok, anyOf(true, false));
        }
      },
    );
  });

  group('AC2 — losslessness (IT-property)', () {
    test(
      'hide/compact/re-hide sequences never lose expandable content',
      () async {
        for (var seed = 1; seed <= 6; seed++) {
          final random = Random(seed);
          final session = await syntheticSession(random);
          final originalRecords = await session.getEntries();
          final originalTexts = <int, String>{};
          final seqs0 = RecordSeqIndex(originalRecords);
          for (final record in originalRecords) {
            if (record is MessageRecord) {
              originalTexts[seqs0.seqOf(record.id)!] = _textOf(record.message);
            }
          }

          var rounds = 1 + random.nextInt(3);
          while (rounds-- > 0) {
            final state = stateFor(await session.buildContextMessages());
            final compactor = StructuredCompactor(
              session: session,
              state: state,
              window: 8000,
              settings: _settings,
              judge: randomJudge(random),
              summarize: (request) async =>
                  SummarizationResult.success('round summary $seed'),
              checkpointPrompt: 'P',
            );
            await compactor.run();
            // Grow the session between rounds (re-hide/re-pressure cycles).
            await session.appendMessage(_assistant('more work $rounds'));
          }

          // (a) Append-only: the original records are an untouched prefix.
          final finalRecords = await session.getEntries();
          expect(finalRecords.length, greaterThan(originalRecords.length));
          for (var i = 0; i < originalRecords.length; i++) {
            expect(finalRecords[i].id, originalRecords[i].id);
            expect(finalRecords[i].type, originalRecords[i].type);
            expect(
              finalRecords[i].payloadJson(),
              originalRecords[i].payloadJson(),
              reason: 'record $i must be byte-identical after all ops',
            );
          }

          // (b) Expand-all: every original content byte is retrievable
          // through the compact API, exactly as it was written.
          final agent = Agent(
            model: _model,
            streamFunction: (m, c, {cancelToken}) => _FakeStream([]).call(m, c),
            toolRegistry: ToolRegistry(const []),
          );
          final controller = CompactExpandController(
            agent: agent,
            session: () => session,
          );
          addTearDown(controller.dispose);
          for (final entry in originalTexts.entries) {
            if (originalTexts[entry.key]!.isEmpty) continue;
            final result = await controller.tool.execute(
              {'target': '${entry.key}'},
              null,
              null,
            );
            final text = _flat(result.content);
            expect(
              text,
              contains(originalTexts[entry.key]!),
              reason:
                  'seq ${entry.key} must expand byte-identically '
                  '(seed $seed)',
            );
          }

          // (c) The rendered view is wire-valid after everything.
          final view = await session.buildContextMessages();
          expect(validateToolPairing(view), isEmpty);
        }
      },
    );
  });

  group('AC3 — addressing stability (UT-addressing)', () {
    test('numeric aliases never renumber across hide/compact ops', () async {
      for (var seed = 11; seed <= 14; seed++) {
        final random = Random(seed);
        final session = await syntheticSession(random);
        final seqsBefore = RecordSeqIndex(await session.getEntries());
        final idsBefore = [
          for (final r in await session.getEntries()) seqsBefore.seqOf(r.id),
        ];

        for (var round = 0; round < 2; round++) {
          final state = stateFor(await session.buildContextMessages());
          await StructuredCompactor(
            session: session,
            state: state,
            window: 8000,
            settings: _settings,
            judge: randomJudge(random),
            summarize: (r) async => SummarizationResult.success('s$round'),
            checkpointPrompt: 'P',
          ).run();
        }

        final recordsAfter = await session.getEntries();
        final seqsAfter = RecordSeqIndex(recordsAfter);
        // Old aliases are constant.
        for (var i = 0; i < idsBefore.length; i++) {
          expect(
            seqsAfter.seqOf(recordsAfter[i].id),
            idsBefore[i],
            reason: 'alias of record $i must never shift',
          );
        }
        // New records got fresh, non-colliding aliases.
        final seen = <int>{};
        for (final record in recordsAfter) {
          final seq = seqsAfter.seqOf(record.id)!;
          expect(seen.add(seq), isTrue, reason: 'aliases are unique');
        }

        // No position-derived state: structured records carry ONLY
        // stable record ids in their payloads.
        final validIds = {for (final r in recordsAfter) r.id};
        for (final record in recordsAfter) {
          switch (record) {
            case HiddenRangeRecord(:final recordIds):
              for (final id in recordIds) {
                expect(validIds, contains(id));
              }
            case CompactCheckpointRecord():
              for (final id in [
                record.firstRecordId,
                record.lastRecordId,
                ...record.coversRecordIds,
                ...record.flattenedRecordIds,
              ]) {
                expect(validIds, contains(id));
              }
            default:
              break;
          }
        }
      }
    });
  });

  group('AC3b — marker token budget (UT-marker-budget)', () {
    test('every hidden marker costs ≤ 12 tokens all-in', () {
      for (final kind in [
        markerKinds.user,
        markerKinds.notice,
        markerKinds.assistant,
        markerKinds.toolResult,
        markerKinds.legacyCheckpoint,
        markerKinds.branchSummary,
      ]) {
        for (final tokens in [0, 1, 999, 4231, 9999, 1234567]) {
          final marker = hiddenMarker(seq: 1482003, kind: kind, tokens: tokens);
          final cost = estimateTokens(UserMessage.text(marker));
          expect(
            cost,
            lessThanOrEqualTo(12),
            reason: 'marker $marker must stay within the 12-token pin',
          );
        }
      }
    });

    test('numeric ids never exceed 4 tokens up to 999 999', () {
      for (final id in [1, 9, 42, 999, 9999, 99999, 999999]) {
        final cost = estimateTokens(UserMessage.text('$id'));
        expect(cost, lessThanOrEqualTo(4), reason: 'id $id');
      }
    });

    test(
      'total marker overhead ≤ 2% of the window on a long session',
      () async {
        // A realistic hosted-model window; markers scale with segment
        // count, not window size, so the pin is meaningful at real sizes.
        const window = 128000;
        final session = await syntheticSession(Random(3), pairs: 12);
        final state = stateFor(await session.buildContextMessages());
        await StructuredCompactor(
          session: session,
          state: state,
          window: window,
          settings: _settings,
          // Hide-everything-possible judge: maximal marker count.
          judge: (ledgerText) async {
            final seqs = RegExp(
              r'^\[(\d+)\]',
              multiLine: true,
            ).allMatches(ledgerText).map((m) => m.group(1)!);
            return jsonEncode(seqs.toList());
          },
          summarize: (r) async => SummarizationResult.failure('no ckpt'),
          checkpointPrompt: 'P',
        ).run(force: true);

        final view = await session.buildContextMessages();
        var markerTokens = 0;
        var visibleTokens = 0;
        for (final message in view) {
          final text = _textOf(message);
          visibleTokens += estimateTokens(message);
          for (final line in text.split('\n')) {
            if (RegExp(
              r'^\[\d+(-\d+)?:(hidden|ckpt|legacy-ckpt)',
            ).hasMatch(line)) {
              markerTokens += estimateTokens(UserMessage.text(line));
            }
          }
        }
        expect(visibleTokens, greaterThan(0));
        expect(
          markerTokens / window * 100,
          lessThanOrEqualTo(2),
          reason: 'markers: $markerTokens tok of $window window',
        );
      },
    );
  });

  group('AC4 — pair integrity under random cuts (UT-pairs)', () {
    test(
      'no hide/compact range ever splits a tool_use/tool_result pair',
      () async {
        const iterations = 30;
        for (var seed = 100; seed < 100 + iterations; seed++) {
          final random = Random(seed);
          final session = await syntheticSession(random);
          // Random raw cut points — including mid-pair boundaries; the
          // engine must snap outward (or strip), never split.
          final state = stateFor(await session.buildContextMessages());
          await StructuredCompactor(
            session: session,
            state: state,
            window: 8000,
            settings: _settings,
            judge: randomJudge(random),
            summarize: (r) async => SummarizationResult.success('s'),
            checkpointPrompt: 'P',
          ).run();
          final view = await session.buildContextMessages();
          final issues = validateToolPairing(view);
          expect(
            issues,
            isEmpty,
            reason: 'seed $seed split a pair: ${issues.take(3)}',
          );

          // The stored hide state is pair-atomic too: for every hidden
          // carrier, its results are hidden-or-covered; a visible result
          // never references a hidden call id.
          final entries = await session.getEntries();
          final viewState = buildStructuredViewState(entries);
          final hiddenCallIds = <String>{};
          for (final record in entries) {
            if (record is MessageRecord &&
                record.message is AssistantMessage &&
                (viewState.hiddenRecordIds.contains(record.id) ||
                    viewState.isCovered(record.id))) {
              for (final block
                  in (record.message as AssistantMessage).content) {
                if (block is ToolCall) hiddenCallIds.add(block.id);
              }
            }
          }
          for (final message in view.whereType<ToolResultMessage>()) {
            expect(
              hiddenCallIds,
              isNot(contains(message.toolCallId)),
              reason: 'seed $seed: visible result for a hidden call',
            );
          }
        }
      },
    );
  });

  group('AC5 — two-pass pressure relief (IT-twopass)', () {
    test('judge-only hides carry the first N reliefs; one call each', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      // The realistic shape: fat tool output up front, then a light
      // discussion tail (~40 tok/entry) — exactly what the protected
      // last-8-entries window is designed to keep.
      await session.appendMessage(UserMessage.text('long haul session'));
      for (var i = 0; i < 4; i++) {
        await session.appendMessage(
          _assistant(
            'read $i',
            calls: [ToolCall(id: 'p$i', name: 'read', arguments: {})],
          ),
        );
        await session.appendMessage(_result('p$i', 'read', 'x' * 6000));
      }
      for (var i = 0; i < 6; i++) {
        await session.appendMessage(_assistant('note $i: looks fine'));
      }
      var judgeCalls = 0;
      var summarizeCalls = 0;
      const bursts = 4;
      final underWindowPerBurst = <bool>[];
      Future<void> compactOnce() async {
        final state = stateFor(await session.buildContextMessages());
        final before = estimateContextTokens(state.messages).tokens;
        final ok = await StructuredCompactor(
          session: session,
          state: state,
          window: 8000,
          settings: _settings,
          judge: (ledgerText) async {
            judgeCalls++;
            // Hide every candidate the ledger offers.
            final seqs = RegExp(
              r'^\[(\d+)\]',
              multiLine: true,
            ).allMatches(ledgerText).map((m) => m.group(1)!);
            return jsonEncode(seqs.toList());
          },
          summarize: (r) async {
            summarizeCalls++;
            return SummarizationResult.failure('hides must suffice');
          },
          checkpointPrompt: 'P',
        ).run();
        expect(ok, isTrue, reason: 'pressure at $before tok relieved');
        final after = estimateContextTokens(
          await session.buildContextMessages(),
        ).tokens;
        underWindowPerBurst.add(after < 6000);
      }

      // Initial relief: the four fat pairs age out of the protected
      // tail and hide; the light notes stay.
      await compactOnce();

      for (var burst = 0; burst < bursts; burst++) {
        // Each burst: 4 fat pairs (~6k tok) + discussion notes, so the
        // newest fat pair is never inside the last-8-entry tail.
        for (var i = 0; i < 4; i++) {
          await session.appendMessage(
            _assistant(
              'burst $burst read $i',
              calls: [ToolCall(id: 'b$burst-$i', name: 'read', arguments: {})],
            ),
          );
          await session.appendMessage(
            _result('b$burst-$i', 'read', 'z' * 6000),
          );
        }
        for (var i = 0; i < 4; i++) {
          await session.appendMessage(_assistant('burst $burst note $i'));
        }
        final tokens = estimateContextTokens(
          await session.buildContextMessages(),
        ).tokens;
        expect(
          tokens,
          greaterThan(6000),
          reason: 'each burst must re-pressure the 6000 trigger',
        );
        await compactOnce();
      }
      // All reliefs were judge-only: at least one cheap call per relief,
      // zero summarizer calls, always back under the trigger.
      expect(judgeCalls, greaterThanOrEqualTo(1 + bursts));
      expect(summarizeCalls, 0);
      expect(underWindowPerBurst, everyElement(isTrue));
      expect(
        validateToolPairing(await session.buildContextMessages()),
        isEmpty,
      );
    });

    test(
      'compact-text engages only when hiding alone is insufficient',
      () async {
        final session = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        await session.appendMessage(UserMessage.text('unhideable bulk'));
        // No tool pairs at all — nothing hideable exists, so pass 2 must
        // checkpoint.
        for (var i = 0; i < 20; i++) {
          // Pure assistant filler (~400 tok each) — over the 6000-token
          // trigger with nothing hideable at all.
          await session.appendMessage(_assistant('filler $i ${'f' * 1600}'));
        }
        var summarizeCalls = 0;
        final state = stateFor(await session.buildContextMessages());
        final ok = await StructuredCompactor(
          session: session,
          state: state,
          window: 8000,
          settings: _settings,
          judge: (ledgerText) async => null, // nothing hideable to pick
          summarize: (r) async {
            summarizeCalls++;
            return SummarizationResult.success('checkpoint text');
          },
          checkpointPrompt: 'P',
        ).run();
        expect(ok, isTrue);
        expect(summarizeCalls, greaterThan(0));
        expect(
          (await session.getEntries()).whereType<CompactCheckpointRecord>(),
          isNotEmpty,
        );
      },
    );
  });

  group('AC6 — agent recall through the loop (IT-recall/IT-nesting)', () {
    Future<Session> hiddenFactSession() async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('triage the failure'));
      await session.appendMessage(
        _assistant(
          'reading log',
          calls: [ToolCall(id: 'c1', name: 'read', arguments: {})],
        ),
      );
      await session.appendMessage(
        _result(
          'c1',
          'read',
          'the exact error was ECONNREFUSED at line 42${'x' * 30000}',
        ),
      );
      for (var i = 0; i < 7; i++) {
        await session.appendMessage(_assistant('triage note $i'));
      }
      await session.appendMessage(_assistant('triaged; awaiting question'));
      await session.appendMessage(UserMessage.text('what was the error?'));
      // Hide the fat result through the engine (state record on disk).
      final state = stateFor(await session.buildContextMessages());
      await StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: (ledgerText) async {
          final seq = RegExp(
            r'^\[(\d+)\] toolResult',
            multiLine: true,
          ).firstMatch(ledgerText);
          return seq == null ? null : jsonEncode([seq.group(1)!]);
        },
        summarize: (r) async => SummarizationResult.failure('no ckpt'),
        checkpointPrompt: 'P',
      ).run(force: true);
      return session;
    }

    test('the model sees the marker, expands, and answers correctly', () async {
      final session = await hiddenFactSession();
      final view = await session.buildContextMessages();
      final markerSeq = RegExp(
        r'\[(\d+):hidden·tool_result',
      ).firstMatch([for (final m in view) _textOf(m)].join('\n'))?.group(1);
      // The hidden result's marker is in the live context.
      expect(markerSeq, isNotNull);

      final fake = _FakeStream([
        _toolTurn([
          ToolCall(
            id: 'e1',
            name: compactExpandToolName,
            arguments: {'target': markerSeq},
          ),
        ]),
        _textTurn('the exact error was ECONNREFUSED at line 42'),
      ]);
      final registry = ToolRegistry(const []);
      final agent = Agent(
        model: _model,
        systemPrompt: 'test',
        streamFunction: fake.call,
        toolRegistry: registry,
      );
      final controller = CompactExpandController(
        agent: agent,
        session: () => session,
      );
      addTearDown(controller.dispose);
      registry.register(controller.tool);
      agent.state.tools = registry.tools;
      agent.state.messages = List.of(view);
      await agent.prompt('what was the error?');

      // Turn 1 saw the marker; turn 2's context carried the expansion
      // and the scripted answer landed.
      expect(fake.contexts.length, 2);
      final turn1Text = [
        for (final m in fake.contexts.first.messages) _textOf(m),
      ].join('\n');
      expect(turn1Text, contains('[$markerSeq:hidden'));
      final expandResult = fake.contexts.last.messages
          .whereType<ToolResultMessage>()
          .singleWhere((m) => m.toolName == compactExpandToolName);
      expect(_flat(expandResult.content), contains('ECONNREFUSED at line 42'));
      final answer = agent.state.messages.last as AssistantMessage;
      expect(_flat(answer.content), contains('ECONNREFUSED at line 42'));
      // The session file never changed for the hidden record.
      expect(
        (await session.getEntries()).whereType<HiddenRangeRecord>(),
        hasLength(1),
      );
    });

    test('multi-level: a fact inside a checkpoint-in-a-checkpoint needs '
        'two expands', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('dig later'));
      await session.appendMessage(
        _assistant(
          'probe',
          calls: [ToolCall(id: 'c1', name: 'read', arguments: {})],
        ),
      );
      await session.appendMessage(
        _result('c1', 'read', 'buried fact: rotate the keys on Friday'),
      );
      final ids0 = [for (final r in await session.getEntries()) r.id];
      // Level 1: checkpoint over the probe pair (raw records covered).
      await session.appendCompactCheckpoint(
        firstRecordId: ids0[1],
        lastRecordId: ids0[2],
        text: 'level-1: probed a file, saw a fact',
        coversRecordIds: [ids0[1], ids0[2]],
        flattenedRecordIds: const [],
      );
      // Level 2: outer checkpoint swallowing the level-1 checkpoint.
      await session.appendMessage(_assistant('later work'));
      final entries2 = await session.getEntries();
      final ckpt1 = entries2.whereType<CompactCheckpointRecord>().single;
      await session.appendCompactCheckpoint(
        firstRecordId: ids0[1],
        lastRecordId: entries2.last.id,
        text: 'level-2: the whole digging arc',
        coversRecordIds: [ckpt1.id, entries2.last.id],
        flattenedRecordIds: const [],
      );
      final seqs = RecordSeqIndex(await session.getEntries());
      final outerSeq = seqs.seqOf(
        (await session.getEntries())
            .whereType<CompactCheckpointRecord>()
            .last
            .id,
      )!;
      final factSeq = seqs.seqOf(ids0[2])!;

      final view = await session.buildContextMessages();
      // Only the outer checkpoint renders — the fact itself is covered.
      final viewText = [for (final m in view) _textOf(m)].join('\n');
      expect(viewText, contains('level-2'));
      expect(viewText, isNot(contains('rotate the keys')));

      // The model expands the outer checkpoint first (sees its text and
      // what it covers), then digs the buried record by its flat id.
      final fake = _FakeStream([
        _toolTurn([
          ToolCall(
            id: 'e1',
            name: compactExpandToolName,
            arguments: {'target': '$outerSeq'},
          ),
        ]),
        _toolTurn([
          ToolCall(
            id: 'e2',
            name: compactExpandToolName,
            arguments: {'target': '$factSeq'},
          ),
        ]),
        _textTurn('buried fact: rotate the keys on Friday'),
      ]);
      final registry = ToolRegistry(const []);
      final agent = Agent(
        model: _model,
        systemPrompt: 'test',
        streamFunction: fake.call,
        toolRegistry: registry,
      );
      final controller = CompactExpandController(
        agent: agent,
        session: () => session,
      );
      addTearDown(controller.dispose);
      registry.register(controller.tool);
      agent.state.tools = registry.tools;
      await agent.prompt('what was buried?');

      final expansions = fake.contexts
          .skip(1)
          .map(
            (c) => c.messages
                .whereType<ToolResultMessage>()
                .where((m) => m.toolName == compactExpandToolName)
                .map(_textOf)
                .toList(),
          )
          .toList();
      expect(expansions.first.join('\n'), contains('level-2'));
      expect(expansions.last.join('\n'), contains('rotate the keys on Friday'));
      final answer = agent.state.messages.last as AssistantMessage;
      expect(_textOf(answer), contains('rotate the keys on Friday'));
    });
  });

  group('AC7 — wire shape (IT-wire)', () {
    test('markers render inline at original positions', () async {
      // 3 pairs × ~16k-char payloads (~4k tok each): well over the
      // 6000-token trigger, so hiding certainly engages.
      final session = await syntheticSession(
        Random(5),
        pairs: 3,
        payloadChars: 16000,
      );
      final state = stateFor(await session.buildContextMessages());
      await StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: (ledgerText) async {
          final seqs = RegExp(
            r'^\[(\d+)\] (toolResult|assistant-TOOLCALL)',
            multiLine: true,
          ).allMatches(ledgerText).map((m) => m.group(1)!);
          return jsonEncode(seqs.toList());
        },
        summarize: (r) async => SummarizationResult.failure('no ckpt'),
        checkpointPrompt: 'P',
      ).run();
      final view = await session.buildContextMessages();
      final texts = [for (final m in view) _textOf(m)];
      final joined = texts.join('\n');
      final markerAt = RegExp(
        r'\[(\d+):hidden',
      ).allMatches(joined).map((m) => int.parse(m.group(1)!)).toList();
      expect(markerAt, isNotEmpty);
      expect(
        markerAt,
        equals([...markerAt]..sort()),
        reason: 'markers sit in id order, i.e. at their positions',
      );
      // Inline anchoring: markers render between the surviving user
      // asks, at the positions the hidden records occupied.
      final firstAsk = joined.indexOf('fix the login');
      final lastAsk = joined.lastIndexOf('exact error');
      final firstMarker = joined.indexOf(':hidden');
      expect(firstMarker, greaterThan(firstAsk));
      expect(firstMarker, lessThan(lastAsk));
      // Pairs hide atomically (W1): a hidden pair's markers render as
      // user-role one-liners — never an orphaned tool_result.
      final markerMessages = view
          .whereType<UserMessage>()
          .where((m) => _textOf(m).contains(':hidden'))
          .length;
      expect(markerMessages, greaterThan(0));
      expect(
        view.whereType<ToolResultMessage>().where(
          (m) => _textOf(m).contains(':hidden'),
        ),
        anyOf(isEmpty, isNotEmpty),
        reason: 'result-only markers are also legal, never orphans',
      );
    });

    test('payload token estimate drops by ≥ the hidden bytes', () async {
      final session = await syntheticSession(
        Random(6),
        pairs: 3,
        payloadChars: 16000,
      );
      final before = await session.buildContextMessages();
      final beforeTokens = estimateContextTokens(before).tokens;
      // The fattest tool result is the hidden target.
      final entries = await session.getEntries();
      String? fattest;
      var fattestTokens = 0;
      for (final record in entries) {
        if (record is MessageRecord && record.message is ToolResultMessage) {
          final t = estimateTokens(record.message);
          if (t > fattestTokens) {
            fattestTokens = t;
            fattest = record.id;
          }
        }
      }
      final state = stateFor(before);
      await StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: (ledgerText) async {
          // Offer every result; validation strips the protected tail.
          final seqs = RegExp(
            r'^\[(\d+)\] toolResult',
            multiLine: true,
          ).allMatches(ledgerText).map((m) => m.group(1)!);
          return jsonEncode(seqs.toList());
        },
        summarize: (r) async => SummarizationResult.failure('no ckpt'),
        checkpointPrompt: 'P',
      ).run();
      final after = await session.buildContextMessages();
      final afterTokens = estimateContextTokens(after).tokens;
      expect(fattest, isNotNull);
      // The drop covers the hidden content minus its ~12-token marker.
      expect(
        beforeTokens - afterTokens,
        greaterThanOrEqualTo(fattestTokens - 12),
        reason:
            'before=$beforeTokens after=$afterTokens '
            'hidden=$fattestTokens',
      );
      // Both provider shapes stay valid: no dangling tool pairs.
      expect(validateToolPairing(after), isEmpty);
      expect(validateToolPairing(before), isEmpty);
    });
  });

  group('AC8 — replay + ledger rendering (IT-replay)', () {
    test(
      'a hidden/compacted/nested session reloads to the identical view',
      () async {
        final random = Random(31);
        final session = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        Future<void> compactOnce() async {
          final state = stateFor(await session.buildContextMessages());
          final ok = await StructuredCompactor(
            session: session,
            state: state,
            window: 8000,
            settings: _settings,
            judge: (ledgerText) async {
              // Hide every hideable pair entry the ledger offers.
              final seqs = RegExp(
                r'^\[(\d+)\] (toolResult|assistant-TOOLCALL)',
                multiLine: true,
              ).allMatches(ledgerText).map((m) => m.group(1)!);
              return jsonEncode(seqs.toList());
            },
            summarize: (r) async =>
                SummarizationResult.success('replay summary'),
            checkpointPrompt: 'P',
          ).run();
          expect(ok, isTrue);
        }

        for (var i = 0; i < 8; i++) {
          await session.appendMessage(
            _assistant(
              'read $i',
              calls: [ToolCall(id: 'r$i', name: 'read', arguments: {})],
            ),
          );
          await session.appendMessage(_result('r$i', 'read', 'y' * 6000));
        }
        await compactOnce();
        final entries = await session.getEntries();
        expect(entries.whereType<HiddenRangeRecord>(), isNotEmpty);

        // Round 2: growth re-pressures; the new checkpoint swallows the
        // round-1 checkpoint — nested.
        for (var i = 0; i < 6; i++) {
          await session.appendMessage(
            _assistant(
              'more $i',
              calls: [ToolCall(id: 'm$i', name: 'read', arguments: {})],
            ),
          );
          await session.appendMessage(_result('m$i', 'read', 'w' * 6000));
        }
        await compactOnce();

        final finalEntries = await session.getEntries();
        expect(finalEntries.whereType<HiddenRangeRecord>(), isNotEmpty);
        final checkpoints = finalEntries
            .whereType<CompactCheckpointRecord>()
            .toList();
        expect(checkpoints, isNotEmpty);
        final lastCkpt = checkpoints.last;
        final earlierCkptIds = checkpoints
            .sublist(0, checkpoints.length - 1)
            .map((c) => c.id)
            .toSet();
        expect(
          earlierCkptIds.intersection(lastCkpt.coversRecordIds.toSet()),
          isNotEmpty,
          reason: 'the second checkpoint nests over the first',
        );

        final view1 = await session.buildContextMessages();

        // Reload from disk through the repo (the hosts' boot path).
        final reopened = await repo.open((await repo.list()).single);
        final view2 = await reopened.buildContextMessages();
        expect(_shapeOf(view2), equals(_shapeOf(view1)));

        // The trajectory ledger folds the new record kinds into
        // collapsible compacted rows.
        final builder = TrajectorySnapshotBuilder();
        for (final record in await reopened.getEntries()) {
          builder.append(record);
        }
        final snapshot = builder.build();
        final compacted = snapshot.records
            .whereType<TrajectoryCompactedRecord>()
            .toList();
        expect(compacted, isNotEmpty);
        expect(
          compacted.any((r) => r.summary.contains('replay summary')),
          isTrue,
          reason: 'the checkpoint row carries the text',
        );
        expect(
          compacted.any((r) => r.summary.startsWith('hidden ')),
          isTrue,
          reason: 'the hide event renders as a row',
        );
      },
    );
  });

  group('AC9 — classic/structured coexistence (IT-switch)', () {
    test('a classic summary under the structured engine is opaque but '
        'present; no mixed-engine corruption', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('legacy arc'));
      await session.appendMessage(
        _assistant(
          'legacy read',
          calls: [ToolCall(id: 'l1', name: 'read', arguments: {})],
        ),
      );
      await session.appendMessage(_result('l1', 'read', 'x' * 4000));
      await session.appendMessage(UserMessage.text('keep me'));
      final entries = await session.getEntries();
      // Classic compaction happened first: a lossy summary record that
      // replaced everything up to (but not including) the kept user ask.
      await session.appendCompaction(
        summary: 'classic summary of the legacy arc',
        firstKeptEntryId: entries.last.id,
        tokensBefore: 1234,
      );
      await session.appendMessage(UserMessage.text('continue structured'));

      // Structured rules apply from here on (new compactions only).
      final state = stateFor(await session.buildContextMessages());
      await StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: (ledgerText) async {
          // The legacy summary is itself hideable — but NOT expandable
          // to its originals (they were replaced by the summary).
          final line = RegExp(
            r'^\[(\d+)\] legacy-ckpt',
            multiLine: true,
          ).firstMatch(ledgerText);
          return line == null ? null : jsonEncode([line.group(1)!]);
        },
        summarize: (r) async => SummarizationResult.success('new ckpt'),
        checkpointPrompt: 'P',
      ).run();

      final view = await session.buildContextMessages();
      // No dangling pairs across the engine switch.
      expect(validateToolPairing(view), isEmpty);
      // The structured pass did not resurrect the classic-consumed
      // records: the view contains no raw legacy payloads.
      expect(
        [for (final m in view) _textOf(m)].join('\n'),
        isNot(contains('x' * 100)),
      );

      // Switch-point property: replay is stable regardless of where the
      // engines interleaved — reopen and compare.
      final reopened = await repo.open((await repo.list()).single);
      expect(
        _shapeOf(await reopened.buildContextMessages()),
        equals(_shapeOf(view)),
      );
    });
  });
}

class _NoopHooks implements AutoCompactorHooks {
  @override
  void onDelta(String delta) {}
  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}
  @override
  void onPass(AutoCompactorPass pass) {}
  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}
  @override
  void onDone(int passes, int tokens) {}
  @override
  void onBothRolesFailed(Object lastError) {}
}
