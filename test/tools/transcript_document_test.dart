// Issue #1886 UT-02/UT-04/UT-05: per-provider response fixtures, Unicode
// fidelity, determinism, and schema invariants for TranscriptDocument.
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _source = TranscriptSource(
  providerKind: 'openai',
  modelId: 'whisper-1',
  baseUrlHost: 'api.openai.com',
);

Map<String, dynamic> _openAiVerboseWithWords() => {
  'task': 'transcribe',
  'language': 'english',
  'duration': 6.2,
  'text': 'Hello world. This is fine.',
  'segments': [
    {'id': 0, 'seek': 0, 'start': 0.0, 'end': 2.5, 'text': ' Hello world.'},
    {'id': 1, 'seek': 250, 'start': 2.5, 'end': 6.2, 'text': ' This is fine.'},
  ],
  'words': [
    {'word': 'Hello', 'start': 0.0, 'end': 0.6},
    {'word': 'world.', 'start': 0.7, 'end': 1.4},
    {'word': 'This', 'start': 2.5, 'end': 2.9},
    {'word': 'is', 'start': 3.0, 'end': 3.2},
    {'word': 'fine.', 'start': 3.3, 'end': 6.0},
  ],
};

Map<String, dynamic> _groqSegmentOnly() => {
  'text': 'one two three',
  'language': 'de',
  'duration': 4.0,
  'segments': [
    {'id': 0, 'start': 0.0, 'end': 2.0, 'text': 'one two'},
    {'id': 1, 'start': 2.0, 'end': 4.0, 'text': ' three'},
  ],
};

/// Every invariant the schema promises, asserted over [document].
void expectInvariantsHold(TranscriptDocument document) {
  for (final segment in document.segments) {
    expect(segment.start.isFinite, isTrue, reason: 'segment ${segment.id}');
    expect(segment.start, greaterThanOrEqualTo(0));
    expect(segment.end, greaterThanOrEqualTo(segment.start));
    for (final word in segment.words ?? const <TranscriptWord>[]) {
      expect(word.start.isFinite, isTrue);
      expect(
        word.start,
        greaterThanOrEqualTo(segment.start),
        reason: 'word "${word.word}" before its segment',
      );
      expect(
        word.end,
        lessThanOrEqualTo(segment.end),
        reason: 'word "${word.word}" after its segment',
      );
      expect(word.end, greaterThanOrEqualTo(word.start));
    }
  }
  final flatWords = [
    ...document.words ?? const <TranscriptWord>[],
    for (final s in document.segments) ...?s.words,
  ];
  for (var i = 1; i < flatWords.length; i++) {
    // Word starts must be non-decreasing within the same stream.
    expect(flatWords[i].start, greaterThanOrEqualTo(flatWords[i - 1].start));
  }
  if (document.segments.isNotEmpty) {
    final joined = TranscriptDocument.normalizeWhitespace(
      document.segments.map((s) => s.text).join(' '),
    );
    expect(
      TranscriptDocument.normalizeWhitespace(document.text),
      joined,
      reason: 'segment concatenation must reproduce text up to whitespace',
    );
  }
}

void main() {
  group('buildTranscriptDocument — OpenAI verbose fixture with words', () {
    final document = parseVerboseTranscriptionPayload(
      payload: _openAiVerboseWithWords(),
      source: _source,
    );

    test('UT-02: parses into a document satisfying every invariant', () {
      expectInvariantsHold(document);
      expect(document.text, 'Hello world. This is fine.');
      expect(document.language, 'english');
      expect(document.durationSeconds, 6.2);
      expect(document.segments, hasLength(2));
      expect(document.source.providerKind, 'openai');
      expect(document.warnings, isEmpty);
    });

    test('UT-02: words nest inside the segments containing their start', () {
      final first = document.segments[0].words!;
      final second = document.segments[1].words!;
      expect(first.map((w) => w.word), ['Hello', 'world.']);
      expect(second.map((w) => w.word), ['This', 'is', 'fine.']);
      // No document-level duplication of nested words.
      expect(document.words, isNull);
    });

    test('AC14: identical fixture bytes produce identical documents', () {
      final again = parseVerboseTranscriptionPayload(
        payload:
            jsonDecode(jsonEncode(_openAiVerboseWithWords()))
                as Map<String, dynamic>,
        source: _source,
      );
      expect(again.toMap(), document.toMap());
      expect(again.toJson(), document.toJson());
    });
  });

  group('UT-02: Groq segment-only fixture', () {
    final document = parseVerboseTranscriptionPayload(
      payload: _groqSegmentOnly(),
      source: const TranscriptSource(
        providerKind: 'groq',
        modelId: 'whisper-large-v3',
        baseUrlHost: 'api.groq.com',
      ),
    );

    test('parses segments, no words, invariants hold', () {
      expectInvariantsHold(document);
      expect(document.segments, hasLength(2));
      expect(document.segments[0].words, isNull);
      expect(document.words, isNull);
      expect(document.language, 'de');
    });
  });

  group('UT-02: plain json and bare-text bodies', () {
    test('plain json {"text": ...} parses to a text-only document', () {
      final document = buildTranscriptDocument(
        text: 'plain transcript',
        source: _source,
      );
      expect(document.text, 'plain transcript');
      expect(document.segments, isEmpty);
      expect(document.warnings, isEmpty);
    });

    test('bare text body (whisper.cpp style) parses as text-only', () {
      final document = buildTranscriptDocument(
        text: 'raw body transcript\n',
        source: _source,
      );
      expect(document.text, 'raw body transcript');
      expect(document.segments, isEmpty);
    });
  });

  group('E4: words without segments', () {
    test('word list stays at document level with invariants', () {
      final document = buildTranscriptDocument(
        text: 'one two',
        source: _source,
        rawWords: [
          {'word': 'one', 'start': 0.0, 'end': 1.0},
          {'word': 'two', 'start': 1.2, 'end': 2.0},
        ],
      );
      expectInvariantsHold(document);
      expect(document.segments, isEmpty);
      expect(document.words, hasLength(2));
    });
  });

  group('E2: silent audio / empty payloads', () {
    test('empty text and absent segments yield a valid empty document', () {
      final document = parseVerboseTranscriptionPayload(
        payload: {'text': '', 'duration': 0.0},
        source: _source,
      );
      expect(document.text, '');
      expect(document.segments, isEmpty);
      expect(document.words, isNull);
      expectInvariantsHold(document);
    });

    test('null text is treated as empty, not an exception', () {
      final document = parseVerboseTranscriptionPayload(
        payload: {'segments': <Object?>[]},
        source: _source,
      );
      expect(document.text, '');
    });

    test('empty word array counts as absent', () {
      final document = parseVerboseTranscriptionPayload(
        payload: {'text': 'x', 'words': <Object?>[]},
        source: _source,
      );
      expect(document.words, isNull);
      expect(document.warnings, isEmpty);
    });
  });

  group('E3/UT-05: malformed timestamps', () {
    test('negative timestamps are dropped with a warning, never clamped', () {
      final document = buildTranscriptDocument(
        text: 'kept',
        source: _source,
        rawSegments: [
          {'id': 0, 'start': -1.0, 'end': 2.0, 'text': 'bad'},
          {'id': 1, 'start': 2.0, 'end': 3.0, 'text': 'kept'},
        ],
      );
      expectInvariantsHold(document);
      expect(document.segments.map((s) => s.id), [1]);
      expect(
        document.warnings.any(
          (w) => w.startsWith(warningInvalidTimestampDropped),
        ),
        isTrue,
      );
    });

    test('NaN/Infinity bounds are dropped with a warning', () {
      final document = buildTranscriptDocument(
        text: '',
        source: _source,
        rawSegments: [
          {'id': 0, 'start': double.nan, 'end': 2.0, 'text': 'nan'},
          {'id': 1, 'start': double.infinity, 'end': 3.0, 'text': 'inf'},
        ],
        rawWords: [
          {'word': 'w', 'start': double.nan, 'end': 1.0},
        ],
      );
      expect(document.segments, isEmpty);
      expect(document.words, isNull);
      expect(
        document.warnings.where(
          (w) => w.startsWith(warningInvalidTimestampDropped),
        ),
        hasLength(3),
      );
    });

    test('start > end is dropped with a warning', () {
      final document = buildTranscriptDocument(
        text: '',
        source: _source,
        rawSegments: [
          {'id': 0, 'start': 3.0, 'end': 1.0, 'text': 'reversed'},
        ],
      );
      expect(document.segments, isEmpty);
      expect(document.warnings, isNotEmpty);
    });

    test('unsorted segments are dropped, never reordered silently', () {
      final document = buildTranscriptDocument(
        text: 'a b c',
        source: _source,
        rawSegments: [
          {'id': 0, 'start': 0.0, 'end': 1.0, 'text': 'a'},
          {'id': 1, 'start': 5.0, 'end': 6.0, 'text': 'c'},
          {'id': 2, 'start': 2.0, 'end': 3.0, 'text': 'b'},
        ],
      );
      expectInvariantsHold(document);
      // The out-of-order segment is REMOVED, not moved into place.
      expect(document.segments.map((s) => s.text), ['a', 'c']);
      expect(
        document.warnings.where(
          (w) => w.startsWith(warningInvalidTimestampDropped),
        ),
        hasLength(1),
      );
    });

    test('non-object entries are dropped with warnings', () {
      final document = buildTranscriptDocument(
        text: '',
        source: _source,
        rawSegments: ['nope', 42, null],
        rawWords: ['also-nope'],
      );
      expect(document.segments, isEmpty);
      expect(document.words, isNull);
      expect(
        document.warnings.where(
          (w) => w.startsWith(warningInvalidTimestampDropped),
        ),
        hasLength(4),
      );
    });

    test('negative/non-finite duration is omitted with a warning', () {
      final document = buildTranscriptDocument(
        text: '',
        source: _source,
        durationSeconds: -5.0,
      );
      expect(document.durationSeconds, isNull);
      expect(
        document.warnings.any((w) => w.startsWith(warningDurationOmitted)),
        isTrue,
      );

      final nan = buildTranscriptDocument(
        text: '',
        source: _source,
        durationSeconds: double.nan,
      );
      expect(nan.durationSeconds, isNull);
      expect(
        nan.warnings.any((w) => w.startsWith(warningDurationOmitted)),
        isTrue,
      );
    });
  });

  group('word clamping (never silent)', () {
    test('word outside its segment is clamped and reported', () {
      final document = buildTranscriptDocument(
        text: 'hi there',
        source: _source,
        rawSegments: [
          {'id': 0, 'start': 1.0, 'end': 2.0, 'text': 'hi there'},
        ],
        rawWords: [
          {'word': 'hi', 'start': 0.2, 'end': 1.2},
          {'word': 'there', 'start': 1.4, 'end': 2.6},
        ],
      );
      expectInvariantsHold(document);
      final words = document.segments[0].words!;
      expect(words[0].start, 1.0); // clamped up to segment start
      expect(words[1].end, 2.0); // clamped down to segment end
      expect(
        document.warnings.where((w) => w.startsWith(warningWordClamped)),
        hasLength(2),
      );
    });
  });

  group('text fidelity invariant', () {
    test('segment text mismatch is repaired with an explicit warning', () {
      final document = buildTranscriptDocument(
        text: 'provider says something entirely different',
        source: _source,
        rawSegments: [
          {'id': 0, 'start': 0.0, 'end': 1.0, 'text': 'segments disagree'},
        ],
      );
      expectInvariantsHold(document);
      expect(document.text, 'segments disagree');
      expect(
        document.warnings.any((w) => w.startsWith(warningTextMismatchRejoined)),
        isTrue,
      );
    });

    test('whitespace-only differences are NOT mismatches', () {
      final document = buildTranscriptDocument(
        text: 'Hello  world.\nThis is fine.',
        source: _source,
        rawSegments: [
          {'id': 0, 'start': 0.0, 'end': 1.0, 'text': 'Hello world.'},
          {'id': 1, 'start': 1.0, 'end': 2.0, 'text': ' This is fine.'},
        ],
      );
      expect(document.text, 'Hello  world.\nThis is fine.');
      expect(document.warnings, isEmpty);
    });
  });

  group('UT-04: Unicode fidelity', () {
    test('Cyrillic and profanity are preserved byte-exactly, unfiltered', () {
      const cyrillic = 'Привет, это проверка — чёрт возьми!';
      final document = buildTranscriptDocument(
        text: cyrillic,
        source: _source,
        rawSegments: [
          {'id': 0, 'start': 0.0, 'end': 1.0, 'text': cyrillic},
        ],
      );
      expect(document.text, cyrillic);
      expect(document.segments[0].text, cyrillic);
      // Byte-exact through the serialized form too.
      expect(
        TranscriptDocument.normalizeWhitespace(document.toJson()),
        contains('Привет'),
      );
    });

    test('language hint and detected language coexist (E11)', () {
      final document = parseVerboseTranscriptionPayload(
        payload: {'text': 'hola', 'language': 'es'},
        source: _source,
      );
      // The detected language is surfaced; the transcript text is untouched.
      expect(document.language, 'es');
      expect(document.text, 'hola');
    });
  });

  group('UT-05: serialization shape (schema v1)', () {
    test('toMap carries schemaVersion, source, and ordered fields', () {
      final document = parseVerboseTranscriptionPayload(
        payload: _openAiVerboseWithWords(),
        source: _source,
      );
      final map = document.toMap();
      expect(map['schemaVersion'], 1);
      expect(map.keys, containsAll(['text', 'segments', 'source', 'warnings']));
      final source = map['source'] as Map<String, dynamic>;
      expect(source, {
        'providerKind': 'openai',
        'modelId': 'whisper-1',
        'baseUrlHost': 'api.openai.com',
      });
      final segment = (map['segments'] as List).first as Map<String, dynamic>;
      expect(
        segment.keys,
        containsAll(['id', 'start', 'end', 'text', 'words']),
      );
    });

    test('round-trips through JSON without losing fidelity', () {
      final document = parseVerboseTranscriptionPayload(
        payload: _openAiVerboseWithWords(),
        source: _source,
      );
      final decoded = jsonDecode(document.toJson()) as Map<String, dynamic>;
      expect(decoded['text'], document.text);
      expect((decoded['segments'] as List).length, document.segments.length);
    });
  });
}
