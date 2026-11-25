// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// GOAL #2394 AC20 — a session written BEFORE 2.1 (a legacy checkpoint
/// and a legacy hidden range, none of the additive fields) needs no
/// migration: it resumes under the new engine (tags on the next request,
/// old markers byte-identical, the first compaction is a merged call
/// over the old chain — REG-15), stays searchable (`session_search`,
/// the `/handoff` collector, `fa session list` — REG-16) and the
/// classic projection ignores the new fields (REG-17).
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'm1',
  api: 'openai-completions',
  provider: 'p',
  baseUrl: 'http://localhost/1',
  contextWindow: 800,
  maxTokens: 4096,
);

const _legacyCheckpointText =
    '## Goal\n- fix the login crash\nopen asks:\n- fix the login crash\n'
    'The crash is a null deref; the guard is half-written.';

const _transfer =
    '## Open User Requests\n- fix the login crash\n'
    '- what was the exact error?\n## Hand-over\n'
    'Second hand-over over the legacy chain: the null deref is fixed.';

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) =>
    AssistantMessage(
      content: [
        TextContent(text: text),
        ...?calls,
      ],
      api: 'openai-completions',
      provider: 'p',
      model: 'm1',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026),
    );

String _textOf(Message m) => switch (m) {
  UserMessage(:final content) =>
    content is String
        ? content
        : (content as List<ContentBlock>)
              .whereType<TextContent>()
              .map((b) => b.text)
              .join('\n'),
  AssistantMessage() =>
    m.content.whereType<TextContent>().map((b) => b.text).join('\n'),
  ToolResultMessage() =>
    m.content.whereType<TextContent>().map((b) => b.text).join('\n'),
  _ => '',
};

final class _Fake {
  _Fake(this.replies);
  final List<String> replies;
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
    final message = _assistant(replies[contexts.length - 1]);
    final stream = AssistantMessageEventStream();
    stream.push(StartEvent(partial: message));
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  }
}

Future<Session> _legacySession(JsonlSessionRepo repo, {int fillers = 3}) async {
  final s = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
  await s.appendMessage(UserMessage.text('fix the login crash'));
  for (var i = 0; i < 3; i++) {
    await s.appendMessage(
      _assistant(
        'step $i',
        calls: [ToolCall(id: 'c$i', name: 'read', arguments: {})],
      ),
    );
    await s.appendMessage(
      ToolResultMessage(
        toolCallId: 'c$i',
        toolName: 'read',
        content: [TextContent(text: 'payload $i ${'x' * 400}')],
        isError: false,
        timestamp: DateTime.utc(2026),
      ),
    );
    await s.appendMessage(_assistant('analysis $i findings'));
  }
  for (var i = 0; i < fillers; i++) {
    await s.appendMessage(_assistant('filler $i'));
  }
  await s.appendMessage(UserMessage.text('what was the exact error?'));
  return s;
}

/// The pre-2.1 shape: a checkpoint and a hidden range written WITHOUT the
/// #2394 keys (exactly what an older binary produced).
Future<Session> _pre21Session(JsonlSessionRepo repo, {int fillers = 3}) async {
  final s = await _legacySession(repo, fillers: fillers);
  final records = await s.getEntries();
  await s.appendCompactCheckpoint(
    firstRecordId: records[0].id,
    lastRecordId: records[3].id,
    text: _legacyCheckpointText,
    coversRecordIds: [for (final r in records.take(4)) r.id],
    flattenedRecordIds: const [],
  );
  await s.appendHiddenRange(recordIds: [records[4].id, records[5].id]);
  return s;
}

Future<String> _raw(MemoryFileSystem fs, Session s) async =>
    (await fs.readTextFile((await s.getMetadata()).path)).valueOrNull ?? '';

List<Map<String, dynamic>> _lines(String raw) => [
  for (final line in raw.split('\n'))
    if (line.isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
];

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  group('REG-15 continuable without migration', () {
    test(
      'the fixture is the pre-2.1 shape (none of the additive keys)',
      () async {
        final s = await _pre21Session(repo);
        final raw = await _raw(fs, s);
        for (final map in _lines(raw)) {
          expect(map.containsKey('labels'), isFalse);
          expect(map.containsKey('consolidated'), isFalse);
          expect(map.containsKey('layout'), isFalse);
        }
        expect(raw, contains('"compact_checkpoint"'));
        expect(raw, contains('"hidden_range"'));
      },
    );

    test('resume: old markers render IN PLACE exactly as before; the file '
        'is never rewritten', () async {
      final s = await _pre21Session(repo);
      final before = await _raw(fs, s);
      final projection = await s.buildTranscriptProjection();
      final texts = [for (final m in projection.messages) _textOf(m)];
      // The legacy checkpoint: header + text + hidden index at the range's
      // own position; the hidden pair keeps its per-record markers with
      // previews — no `[expand …]` pointer, no consolidated marker.
      expect(texts.first, startsWith('[2-5:ckpt·'));
      expect(texts.first, contains('open asks:'));
      expect(texts.first, contains('\n[2:hidden·user·'));
      expect(texts[1], startsWith('[6:hidden·assistant·'));
      expect(texts[2], startsWith('[7:hidden·tool_result·'));
      expect(texts.any((t) => t.contains('[expand ')), isFalse);
      expect(await _raw(fs, s), before);
    });

    test('the first request after resume tags EVERY visible record of the '
        'old chain (epoch = load)', () async {
      final s = await _pre21Session(repo);
      final projection = await s.buildTranscriptProjection();
      final tagged = tagTranscript(projection.messages, projection.seqMap);
      final texts = [for (final m in tagged) _textOf(m)];
      // The last user turn is seq 15; the filler before it seq 14.
      expect(texts.last, 'm15 what was the exact error?');
      expect(texts[texts.length - 2], startsWith('m14 filler 2'));
      for (var i = 0; i < tagged.length; i++) {
        final seq = projection.seqMap.seqAt(i);
        if (seq != null) expect(texts[i], startsWith('m$seq '));
      }
    });

    test('the first compaction after resume is a merged call over the old '
        'chain; new records append after the untouched legacy ones', () async {
      // Six filler turns keep the step-2 pair (seqs 9-10) outside the
      // protected tail, so the hide pick has something to dispose.
      final s = await _pre21Session(repo, fillers: 6);
      final before = await _raw(fs, s);
      final legacyLines = before.split('\n');
      final projection = await s.buildTranscriptProjection();
      final snapshot = RequestSnapshot(
        model: _model,
        messages: tagTranscript(projection.messages, projection.seqMap),
        systemPrompt: 'sys',
        tools: const [Tool(name: 'read', description: 'd', parameters: {})],
        seqMap: projection.seqMap,
        sentAt: DateTime.now(),
      );
      // The hide pick names the step-2 pair (seqs 9-10): outside the fold
      // range and the tail → snapped and hidden.
      final fake = _Fake(['9-10 stale read output\n-\n$_transfer']);
      final hooks = _Hooks();
      final compactor = StructuredCompactor(
        session: s,
        state: AgentState(model: _model, messages: []),
        window: 800,
        // A small keep-recent so the short fixture leaves a foldable
        // prefix under the keep-recent walk.
        settings: const CompactionSettings(
          enabled: true,
          reserveTokens: 200,
          keepRecentTokens: 100,
        ),
        judge: (text, [token]) async => throw StateError('judge must not run'),
        summarize: (request) async =>
            throw StateError('digest must not run on the merged path'),
        checkpointPrompt: 'P',
        handOver: handOverCallAdapter(
          stream: fake.call,
          model: _model,
          cachePolicy: CompactionCachePolicy.sessionAffine(),
          prefixLength: snapshot.prefixLength,
        ),
        requestSnapshot: snapshot,
        handOverPrompt: compactionHandOverPrompt,
        hooks: hooks,
        pinnedLines: const {},
      );
      expect(await compactor.run(force: true), isTrue);
      expect(hooks.passes.single.kind, 'hand-over');
      expect(hooks.passes.single.handOver, isNotNull);
      final after = await _raw(fs, s);
      expect(after.startsWith(before), isTrue);
      final legacyPrefix = [
        for (final line in legacyLines)
          if (line.isNotEmpty) line,
      ];
      final afterLines = after.split('\n');
      expect(afterLines.sublist(0, legacyPrefix.length), legacyPrefix);
      final newLines = _lines(
        afterLines.sublist(legacyPrefix.length).join('\n'),
      );
      expect(newLines, isNotEmpty);
      expect(newLines.any((m) => m['layout'] == 'tail'), isTrue);
      expect(
        newLines
            .where((m) => m['type'] == 'hidden_range')
            .single['consolidated'],
        isTrue,
      );
      expect(
        newLines.where((m) => m['type'] == 'hidden_range').single['labels'],
        isA<Map>(),
      );
    });
  });

  group('REG-16 searchable', () {
    test('session_search finds the OLD checkpoint text and the NEW '
        'transfer text; the /handoff collector and `fa session list` read '
        'the same file', () async {
      final s = await _pre21Session(repo);
      final records = await s.getEntries();
      await s.appendCompactCheckpoint(
        firstRecordId: records[8].id,
        lastRecordId: records[13].id,
        text: _transfer,
        coversRecordIds: [for (final r in records.skip(8).take(6)) r.id],
        flattenedRecordIds: const [],
        layout: compactCheckpointLayoutTail,
      );
      final path = (await s.getMetadata()).path;
      final old = await searchSessionFile(
        fs,
        path,
        SessionSearchQuery.fromArgs({'query': 'guard is half-written'}),
      );
      expect(old.hits, hasLength(1));
      expect(old.hits.single.kind, contains('checkpoint'));
      final transferred = await searchSessionFile(
        fs,
        path,
        SessionSearchQuery.fromArgs({'query': 'legacy chain'}),
      );
      expect(transferred.hits, hasLength(1));
      final ask = await searchSessionFile(
        fs,
        path,
        SessionSearchQuery.fromArgs({'query': 'fix the login crash'}),
      );
      expect(ask.hits.map((h) => h.kind), contains('message'));
      // `/handoff` reads every record of the branch, old and new alike.
      final branch = await collectEntriesForHandoff(s);
      expect(
        branch.length,
        greaterThanOrEqualTo((await s.getEntries()).length),
      );
      expect(
        branch.whereType<CompactCheckpointRecord>().map((r) => r.text),
        contains(_transfer),
      );
      // `fa session list` (repo.list) still sees the session.
      final listed = await repo.list();
      expect(listed, hasLength(1));
      expect(listed.single.path, path);
    });
  });

  group('REG-17 classic golden', () {
    test('the classic engine record projects as before, and the classic '
        'projection ignores the #2394 hidden-range fields', () async {
      // The classic engine's own record (a `CompactionRecord`) — untouched
      // by 2.1: the covered records drop, the summary rides as a message,
      // no structured marker appears.
      final classic = await _legacySession(repo);
      final records = await classic.getEntries();
      await classic.appendCompaction(
        summary: 'earlier marathon digest: the login crash was a null deref',
        firstKeptEntryId: records[10].id,
        tokensBefore: 1234,
      );
      final classicContext = [
        for (final m in await classic.buildContextMessages()) _textOf(m),
      ];
      expect(classicContext.any((t) => t.contains('marathon digest')), isTrue);
      expect(classicContext.any((t) => t.contains(':ckpt·')), isFalse);
      expect(classicContext.any((t) => t.contains('[expand ')), isFalse);
      // The classic engine's record kind and projection are untouched by
      // 2.1: no structured marker, no expand pointer, the digest rides.
      expect(classicContext.any((t) => t.contains('[expand ')), isFalse);
    });
  });
}

final class _Hooks implements StructuredCompactorHooks {
  final passes = <StructuredCompactionPass>[];

  @override
  void onDelta(String delta) {}

  @override
  void onPass(StructuredCompactionPass pass) => passes.add(pass);
}
