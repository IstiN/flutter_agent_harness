// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1425 — structured-compaction fold replay equivalence at resume.
///
/// AC1: the projection a windowed resume builds over the walked branch is
/// byte-identical (role + text shape) to the projection the live full
/// session renders — the boundary walk reconstructs the whole kept path,
/// and the fold chain (hidden ranges + nested checkpoints) applies the
/// same way on both sides.
///
/// AC2: a fold record whose referenced ids do not resolve on the projected
/// path (older shape / rebuilt ids across a version boundary) is dropped
/// WHOLE with a visible resume note naming the dropped generation — never
/// silently half-applied.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart';
import 'package:flutter_agent_harness/src/session/windowed_session_storage.dart';
import 'package:test/test.dart';

/// Flattens raw message content (String or block list) to text.
String _flat(Object? content) => content is String
    ? content
    : (content as List<Object>)
          .whereType<TextContent>()
          .map((b) => b.text)
          .join('\n');

/// Role + flattened text of every projected message — the byte-shape
/// comparison basis (same signature style as the resume parity suite).
List<String> _shapeOf(List<Message> messages) => [
  for (final m in messages)
    switch (m) {
      UserMessage() => 'user:${_flat(m.content)}',
      AssistantMessage() =>
        'assistant:${m.content.whereType<TextContent>().map((b) => b.text).join('|')}',
      ToolResultMessage(:final toolCallId) => 'tool:$toolCallId',
      _ => m.runtimeType.toString(),
    },
];

/// Builds the marathon fixture: 1200 messages with a classic compaction
/// boundary at e450 (firstKeptEntryId e380 — the kept region is the 70
/// records the compaction retained), structured folds over e470..e579,
/// and a long visible tail. The doubling walk bottoms out at e401 —
/// inside the kept region — which is the geometry the fix addresses.
/// Returns the JSONL text.
String _marathonJsonl() {
  const iso = '2026-01-01T00:00:00.000Z';
  const count = 1200;
  const boundary = 450;
  const firstKept = 380;
  final buffer = StringBuffer(
    '{"type":"session","version":3,"id":"marathon","timestamp":"$iso",'
    '"cwd":"/work"}\n',
  );
  String message(String id, String parent, String text) =>
      '{"type":"message","id":"$id","parentId":$parent,"timestamp":"$iso",'
      '"message":{"role":"user","content":[{"type":"text","text":'
      '${jsonEncode(text)}]}}\n';

  for (var i = 0; i < count; i++) {
    if (i == boundary) {
      buffer.write(
        '{"type":"compaction","id":"c$i","parentId":"e${i - 1}",'
        '"timestamp":"$iso","summary":"earlier marathon context",'
        '"firstKeptEntryId":"e$firstKept","tokensBefore":99999}\n',
      );
    }
    buffer.write(
      message(
        'e$i',
        i == 0
            ? 'null'
            : i == boundary
            ? '"c$i"'
            : '"e${i - 1}"',
        'body $i ${'a' * 40}',
      ),
    );    if (i == 599) {
      // The structured fold chain, appended after the records they fold
      // (the engine's real order): two hidden ranges + two nested
      // checkpoints covering e470..e579.
      buffer.write(
        '{"type":"hidden_range","id":"h600","parentId":"e599",'
        '"timestamp":"$iso","recordIds":['
        '${[for (var j = 470; j <= 529; j++) '"e$j"'].join(',')}]}\n',
      );
      buffer.write(
        '{"type":"compact_checkpoint","id":"cc601","parentId":"h600",'
        '"timestamp":"$iso","firstRecordId":"e470","lastRecordId":"e529",'
        '"text":"checkpoint one: early tail work",'
        '"coversRecordIds":['
        '${[for (var j = 470; j <= 529; j++) '"e$j"'].join(',')}],'
        '"flattenedRecordIds":[]}\n',
      );
      buffer.write(
        '{"type":"hidden_range","id":"h602","parentId":"cc601",'
        '"timestamp":"$iso","recordIds":['
        '${[for (var j = 530; j <= 579; j++) '"e$j"'].join(',')}]}\n',
      );
      buffer.write(
        '{"type":"compact_checkpoint","id":"cc603","parentId":"h602",'
        '"timestamp":"$iso","firstRecordId":"e470","lastRecordId":"e579",'
        '"text":"checkpoint two: the whole folded tail",'
        '"coversRecordIds":['
        '${[for (var j = 470; j <= 579; j++) '"e$j"'].join(',')}],'
        '"flattenedRecordIds":["cc601"]}\n',
      );
    }
  }
  return buffer.toString();
}

void main() {
  late MemoryFileSystem fs;
  const path = '/sessions/marathon.jsonl';

  setUp(() {
    fs = MemoryFileSystem();
  });

  group('AC1 — resume projection equals the live projection', () {
    Future<List<Message>> liveProjection() async {
      await fs.writeFile(path, _marathonJsonl());
      final storage = await JsonlSessionStorage.open(fs, path);
      return Session(storage).buildContextMessages();
    }

    Future<List<Message>> resumedProjection() async {
      await fs.writeFile(path, _marathonJsonl());
      final storage = await WindowedSessionStorage.open(
        fs,
        path,
        chunkRecords: 50,
        residentRecords: 100,
      );
      // The CLI resume walk (the found-stop, no budget — the boundary is
      // reachable for this fixture).
      final ok = await storage.growOlderUntil((r) => r is CompactionRecord);
      expect(ok, isTrue);
      return Session(storage).buildContextMessages();
    }

    test('byte-shape equality over the boundary fixture (the kept region '
        'survives the walk; the fold chain applies identically)',
        () async {
      final live = await liveProjection();
      final resumed = await resumedProjection();

      // The fixture must genuinely exercise the geometry: live renders
      // the kept region (e430..e469) and the fold chain markers.
      final liveTexts = _shapeOf(live);
      expect(
        liveTexts.where((s) => s.contains('body 430 ')),
        isNotEmpty,
        reason: 'fixture check: the kept region renders live',
      );
      expect(
        liveTexts.where((s) => s.contains(':ckpt·')),
        isNotEmpty,
        reason: 'fixture check: the nested checkpoint marker renders live',
      );
      expect(
        liveTexts.where((s) => s.contains('body 500 ')),
        isEmpty,
        reason: 'fixture check: folded records do not render live',
      );

      expect(
        _shapeOf(resumed),
        liveTexts,
        reason: 'the resumed projection must be byte-identical to the '
            'pre-close live projection',
      );
    });
  });

  group('AC2 — all-or-note fold resolution', () {
    Future<List<SessionRecord>> pathOf(String jsonl) async {
      await fs.writeFile(path, jsonl);
      final storage = await JsonlSessionStorage.open(fs, path);
      return storage.getPathToRoot(await storage.getLeafId());
    }

    test('a hidden range referencing a missing record is dropped WHOLE and '
        'named by a resume note — no silent partial hide', () async {
      const iso = '2026-01-01T00:00:00.000Z';
      final jsonl = StringBuffer(
        '{"type":"session","version":3,"id":"skew","timestamp":"$iso",'
        '"cwd":"/work"}\n'
        '{"type":"message","id":"u1","parentId":null,"timestamp":"$iso",'
        '"message":{"role":"user","content":[{"type":"text","text":'
        '"visible one"}]}}\n'
        '{"type":"message","id":"u2","parentId":"u1","timestamp":"$iso",'
        '"message":{"role":"user","content":[{"type":"text","text":'
        '"visible two"}]}}\n'
        // Older-generation shape: hides u2 AND a record this file does
        // not contain (rebuilt ids / partial write).
        '{"type":"hidden_range","id":"h3","parentId":"u2","timestamp":"$iso",'
        '"recordIds":["u2","ghost-9"]}\n',
      ).toString();
      final path = await pathOf(jsonl);
      final seqs = RecordSeqIndex(path);

      final messages = renderStructuredMessages(
        path: path,
        seqs: seqs,
        projectEntry: (record) => switch (record) {
          MessageRecord(:final message) => [message],
          _ => const <Message>[],
        },
      );

      final texts = _shapeOf(messages);
      // All-or-note: NO id of the broken fold half-applied — u2 renders
      // unfolded, no hidden marker for it anywhere.
      expect(
        texts.where((s) => s.contains(':hidden·')),
        isEmpty,
        reason: 'the broken fold must not partially apply',
      );
      expect(texts.where((s) => s.contains('visible two')), isNotEmpty);
      // The note names the dropped generation: fold kind, position, and
      // the unresolved count.
      final note = texts.firstWhere((s) => s.contains('[resume]'));
      expect(note, contains('hidden_range'));
      expect(note, contains('1'));
      expect(note, contains('no longer resolve'));
    });

    test('an empty-shape checkpoint (covers lost in an older format) is '
        'dropped WHOLE with a note — its text never renders as a valid '
        'checkpoint', () async {
      const iso = '2026-01-01T00:00:00.000Z';
      final jsonl = StringBuffer(
        '{"type":"session","version":3,"id":"skew2","timestamp":"$iso",'
        '"cwd":"/work"}\n'
        '{"type":"message","id":"u1","parentId":null,"timestamp":"$iso",'
        '"message":{"role":"user","content":[{"type":"text","text":'
        '"old message"}]}}\n'
        '{"type":"compact_checkpoint","id":"cc2","parentId":"u1",'
        '"timestamp":"$iso","firstRecordId":"u1","lastRecordId":"u1",'
        '"text":"checkpoint text from an incompatible writer",'
        '"coversRecordIds":[],"flattenedRecordIds":[]}\n',
      ).toString();
      final path = await pathOf(jsonl);
      final seqs = RecordSeqIndex(path);

      final messages = renderStructuredMessages(
        path: path,
        seqs: seqs,
        projectEntry: (record) => switch (record) {
          MessageRecord(:final message) => [message],
          _ => const <Message>[],
        },
      );

      final texts = _shapeOf(messages);
      // The stale checkpoint text must not pose as a live summary…
      expect(
        texts.join('\n'),
        isNot(contains('checkpoint text from an incompatible writer')),
      );
      expect(texts.where((s) => s.contains(':ckpt·')), isEmpty);
      // …and the covered record renders unfolded under the note.
      expect(texts.where((s) => s.contains('old message')), isNotEmpty);
      expect(texts.where((s) => s.contains('[resume]')), isNotEmpty);
    });

    test('healthy folds render exactly as before — no note, no shape change '
        '(REG-1)', () async {
      const iso = '2026-01-01T00:00:00.000Z';
      final jsonl = StringBuffer(
        '{"type":"session","version":3,"id":"healthy","timestamp":"$iso",'
        '"cwd":"/work"}\n'
        '{"type":"message","id":"u1","parentId":null,"timestamp":"$iso",'
        '"message":{"role":"user","content":[{"type":"text","text":'
        '"hidden one"}]}}\n'
        '{"type":"message","id":"u2","parentId":"u1","timestamp":"$iso",'
        '"message":{"role":"user","content":[{"type":"text","text":'
        '"visible two"}]}}\n'
        '{"type":"hidden_range","id":"h3","parentId":"u2","timestamp":"$iso",'
        '"recordIds":["u1"]}\n',
      ).toString();
      final path = await pathOf(jsonl);
      final seqs = RecordSeqIndex(path);

      final messages = renderStructuredMessages(
        path: path,
        seqs: seqs,
        projectEntry: (record) => switch (record) {
          MessageRecord(:final message) => [message],
          _ => const <Message>[],
        },
      );

      final texts = _shapeOf(messages);
      expect(texts.join('\n'), isNot(contains('[resume]')));
      expect(texts.where((s) => s.contains('[1:hidden·user·')), isNotEmpty);
      expect(texts.where((s) => s.contains('visible two')), isNotEmpty);
    });

    test('references below a classic compaction kept-start are exempt — '
        'the legacy dropped prefix stays silent (no note)', () async {
      const iso = '2026-01-01T00:00:00.000Z';
      final jsonl = StringBuffer(
        '{"type":"session","version":3,"id":"exempt","timestamp":"$iso",'
        '"cwd":"/work"}\n'
        '{"type":"message","id":"u1","parentId":null,"timestamp":"$iso",'
        '"message":{"role":"user","content":[{"type":"text","text":'
        '"dropped prefix"}]}}\n'
        '{"type":"compaction","id":"c2","parentId":"u1","timestamp":"$iso",'
        '"summary":"prefix summarized","firstKeptEntryId":"c2",'
        '"tokensBefore":10}\n'
        '{"type":"message","id":"u3","parentId":"c2","timestamp":"$iso",'
        '"message":{"role":"user","content":[{"type":"text","text":'
        '"kept message"}]}}\n'
        // References the dropped prefix — classic-dropped, never rendered:
        // legacy silence preserved.
        '{"type":"hidden_range","id":"h4","parentId":"u3","timestamp":"$iso",'
        '"recordIds":["u1"]}\n',
      ).toString();
      final path = await pathOf(jsonl);
      final seqs = RecordSeqIndex(path);

      final messages = renderStructuredMessages(
        path: path,
        seqs: seqs,
        projectEntry: (record) => switch (record) {
          MessageRecord(:final message) => [message],
          _ => const <Message>[],
        },
      );

      expect(
        _shapeOf(messages).join('\n'),
        isNot(contains('[resume]')),
        reason: 'classic-dropped references are exempt from the loud note',
      );
    });
  });
}
