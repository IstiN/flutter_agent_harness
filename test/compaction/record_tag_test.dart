// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// GOAL #2394 — the `record_tag` wire protocol (AC8): form/position of the
/// `m<seq>` tag, the tag epoch (head exact, live edge untagged, non-records
/// untagged), wire-only stamping on a COPY, the pressure-basis `tagOverhead`
/// term, and `Context.toJson` untouched.

library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart';
import 'package:test/test.dart';

MessageRecord _record(String id, Message message) => MessageRecord(
  id: id,
  parentId: null,
  timestamp: DateTime.utc(2026),
  message: message,
);

AssistantMessage _assistant(List<ContentBlock> content) => AssistantMessage(
  content: content,
  api: 'anthropic-messages',
  provider: 'p',
  model: 'm1',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

ToolResultMessage _result(List<ContentBlock> content) => ToolResultMessage(
  toolCallId: 'c1',
  toolName: 'bash',
  content: content,
  isError: false,
  timestamp: DateTime.utc(2026),
);

/// What the gh-2412 finalize seam (`stripRecordTagEcho`) leaves of a
/// one-text-block reply [text] — the parity oracle for the stream filter.
String _seamStrippedText(String text) {
  final cleaned = stripRecordTagEcho(_assistant([TextContent(text: text)]));
  final blocks = cleaned.content.whereType<TextContent>().toList();
  return blocks.isEmpty ? '' : blocks.first.text;
}

ImageContent _image() => ImageContent(mimeType: 'image/png', data: 'AAAA');

RecordSeqIndex _index(List<MessageRecord> records) =>
    RecordSeqIndex([for (final record in records) record]);

TranscriptSeqMap _map(List<int?> head, [RecordSeqIndex? index]) =>
    TranscriptSeqMap(headSeqs: head, index: index ?? _index(const []));

void main() {
  group('UT-11 record tag form and position', () {
    test('prefixes the first text block of a plain user message', () {
      final tagged =
          tagRecordMessage(
                UserMessage.text('fix 2321', timestamp: DateTime.utc(2026)),
                3,
              )
              as UserMessage;
      expect(tagged.content, 'm3 fix 2321');
      expect(leadingRecordTag(tagged.content as String), 3);
    });

    test('image-only record gets a new first text block m<N> image/<mime>', () {
      final tagged =
          tagRecordMessage(_result([_image()]), 61) as ToolResultMessage;
      expect(tagged.content.first, isA<TextContent>());
      expect((tagged.content.first as TextContent).text, 'm61 image/image/png');
      // E18: the image part is untouched and no base64 rides the tag.
      expect(
        (tagged.content.first as TextContent).text,
        isNot(contains('AAAA')),
      );
      expect(tagged.content[1].toJson(), _image().toJson());
    });

    test('E17: pure tool-call carrier gets a tag-only text block', () {
      final call = ToolCall(id: 'c1', name: 'bash', arguments: {'cmd': 'ls'});
      final tagged =
          tagRecordMessage(_assistant([call]), 179) as AssistantMessage;
      expect(tagged.content.first, isA<TextContent>());
      expect((tagged.content.first as TextContent).text, 'm179');
      expect(tagged.content[1], same(call));
    });

    test(
      'assistant thinking blocks keep their position — tag goes to the text after them',
      () {
        final thinking = ThinkingContent(
          thinking: 'hmm',
          thinkingSignature: 'sig',
        );
        final tagged =
            tagRecordMessage(
                  _assistant([thinking, TextContent(text: 'answer')]),
                  4,
                )
                as AssistantMessage;
        expect(tagged.content.first, same(thinking));
        expect((tagged.content[1] as TextContent).text, 'm4 answer');
      },
    );

    test('UT-11 budget: the tag is ≤ 5 tokens by the chars/4 heuristic', () {
      for (final seq in [1, 142, 99999, 999999]) {
        expect(
          estimateStringTokens('${recordTag(seq)} '),
          lessThanOrEqualTo(recordTagTokens),
        );
      }
      expect(recordTagTokens, 5);
      expect(tagOverheadTokens(180), 900);
      expect(tagOverheadTokens(0), 0);
    });

    test('UT-18 (E23): estimateRequestTokens carries the tagOverhead term', () {
      final messages = [
        UserMessage.text('a', timestamp: DateTime.utc(2026)),
        UserMessage.text('b', timestamp: DateTime.utc(2026)),
      ];
      final base = estimateRequestTokens(messages, systemPrompt: 'sys');
      final tagged = estimateRequestTokens(
        messages,
        systemPrompt: 'sys',
        recordSeqs: const [2, null],
      );
      expect(tagged, base + recordTagTokens);
      // A usage anchor prices everything up to it: only later tags count.
      final anchored = [
        _assistant([TextContent(text: 'reply')]).copyWith(
          usage: const Usage(
            input: 100,
            output: 1,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 101,
            cost: UsageCost(),
          ),
        ),
        UserMessage.text('b', timestamp: DateTime.utc(2026)),
      ];
      final anchoredBase = estimateRequestTokens(anchored);
      expect(
        estimateRequestTokens(anchored, recordSeqs: const [2, 3]),
        anchoredBase + recordTagTokens,
      );
      expect(
        estimateRequestTokens(
          anchored,
          systemPrompt: 'sys',
          recordSeqs: const [2, 3],
        ),
        anchoredBase + recordTagTokens,
        reason: 'the anchor already priced the system prompt',
      );
    });
  });

  group('UT-18/UT-19 tag epoch', () {
    final records = [
      _record('a', UserMessage.text('ask', timestamp: DateTime.utc(2026))),
      _record('b', _assistant([TextContent(text: 'reply')])),
      _record('c', _result([TextContent(text: 'out')])),
    ];

    test('head messages carry their exact alias; non-records are null', () {
      final map = _map([2, 3, 4, null, null], _index(records));
      expect(map.seqAt(0), 2);
      expect(map.seqAt(1), 3);
      expect(map.seqAt(3), isNull, reason: 'obligations block is not a record');
      expect(map.seqAt(4), isNull, reason: 'working-set block is not a record');
      expect(map.recordIdAt(1), 'b');
      expect(map.recordIdAt(3), isNull);
    });

    test('UT-18/E30: the live edge carries NO tag inside the epoch', () {
      final map = _map([2, 3, 4, null], _index(records));
      expect(map.seqAt(4), isNull, reason: 'live edge: no alias yet');
      expect(map.seqAt(5), isNull);
      expect(map.recordIdAt(4), isNull);
      final live = [
        ...[for (final r in records) r.message],
        UserMessage.text('go', timestamp: DateTime.utc(2026)),
      ];
      final tagged = tagTranscript(live, map);
      expect((tagged.last as UserMessage).content, 'go');
      expect(map.seqsFor(live.length), [2, 3, 4, null]);
    });

    test('E30: the next epoch tags what the live edge persisted — head bytes '
        'stay stable, the run boundary is the one uncached span', () {
      final epoch1 = _map([2, 3, 4], _index(records));
      final live = [
        ...[for (final r in records) r.message],
        _assistant([TextContent(text: 'new')]),
      ];
      final epoch2 = _map([2, 3, 4, 5], _index(records));
      // Inside the epoch the new message is untagged; the next epoch
      // tags it (one segment) while every head message keeps its bytes.
      expect(
        [for (final m in tagTranscript(live, epoch1).take(3)) m.toJson()],
        [for (final m in tagTranscript(live, epoch2).take(3)) m.toJson()],
      );
      expect(
        (tagTranscript(live, epoch1).last as AssistantMessage).content
            .whereType<TextContent>()
            .first
            .text,
        'new',
      );
      expect(
        (tagTranscript(live, epoch2).last as AssistantMessage).content
            .whereType<TextContent>()
            .first
            .text,
        'm5 new',
      );
    });

    test('record-less projection tags nothing', () {
      expect(_map([null, null]).seqAt(2), isNull);
    });
  });

  group('wire-only stamping on a COPY', () {
    test(
      'tagTranscript never mutates the transcript; untagged entries are identical',
      () {
        final a = UserMessage.text('ask', timestamp: DateTime.utc(2026));
        final b = _result([TextContent(text: 'out')]);
        final block = UserMessage.text(
          '<obligations>',
          timestamp: DateTime.utc(2026),
        );
        final transcript = [a, b, block];
        final map = _map([2, 3, null]);
        final tagged = tagTranscript(transcript, map);
        expect(tagged, isNot(same(transcript)));
        expect(a.content, 'ask');
        expect(b.content.single, isA<TextContent>());
        expect((b.content.single as TextContent).text, 'out');
        expect(tagged[2], same(block));
        expect(
          (tagged[1] as ToolResultMessage).content.single,
          isA<TextContent>(),
        );
        expect(
          ((tagged[1] as ToolResultMessage).content.single as TextContent).text,
          'm3 out',
        );
      },
    );

    test(
      'UT-19: Context.toJson has no index snapshot; tagged copies serialize as plain messages',
      () {
        final context = Context(
          systemPrompt: 'sys',
          messages: [UserMessage.text('ask', timestamp: DateTime.utc(2026))],
          tools: const [],
        );
        final json = context.toJson();
        // No index snapshot, no seq sidecar — the wire protocol is unchanged.
        expect(
          json.keys,
          unorderedEquals(['systemPrompt', 'messages', 'tools']),
        );
        final tagged = tagContext(context, _map([2]));
        expect(tagged.toJson(), {
          'systemPrompt': 'sys',
          'messages': [tagged.messages.single.toJson()],
          'tools': [],
        });
        expect(tagged.toJson()['messages'].single['content'], 'm2 ask');
        expect(tagContext(context, null), same(context));
      },
    );

    test('stamping is idempotent — a tagged copy is not double-tagged', () {
      final map = _map([7]);
      final once = tagTranscript([
        UserMessage.text('x', timestamp: DateTime.utc(2026)),
      ], map);
      expect(tagTranscript(once, map), same(once));
    });

    test(
      'E16: stripRecordTags removes echoed wire tags at line starts only',
      () {
        expect(
          stripRecordTags('m142 old list\nkeep m143 inline\nm9 [expand 9-10]'),
          'old list\nkeep m143 inline\n[expand 9-10]',
        );
        expect(hasRecordTag('[3:hidden·tool_result·12]'), isFalse);
      },
    );

    group('gh-2472: RecordTagEchoStreamFilter (render-path echo hygiene)', () {
      /// Feeds [chunks] through a fresh filter, flushing at the end.
      String streamed(List<String> chunks) {
        final filter = RecordTagEchoStreamFilter();
        return [
          for (final chunk in chunks) filter.push(chunk),
          filter.flush(),
        ].join();
      }

      test('a whole-delta tag is swallowed without flicker', () {
        expect(
          streamed(['m1482 ', 'Принято. Ставлю ватч…']),
          'Принято. Ставлю ватч…',
        );
      });

      test('a tag split across deltas never flickers a fragment', () {
        // The user-facing contract (gh-2472): the intermediate `m14`
        // fragment must never be emitted — the classification waits for
        // the byte that decides tag vs text.
        expect(streamed(['m14', '82 Принято…']), 'Принято…');
        expect(streamed(['m', '1', '4', '8', '2', ' ', 'x']), 'x');
      });

      test('multi-line: every line start is classified independently', () {
        expect(
          streamed(['m1482 Один\n', 'm1494\n', 'm1510 Два']),
          'Один\nm1494\nДва',
        );
      });

      test(
        'a message-initial undecided tail is a leading alias — stripped',
        () {
          // gh-2472 review: the gh-2412 echo contract has a SECOND rule —
          // `_leadingAlias` (`^m\d+(?=\s|$)`, record_tag_echo.dart) strips a
          // reply that OPENS with an alias even without a trailing space:
          // `m3208` is a reply that is ONLY its tag (the tagging machinery
          // itself emits tag-only text blocks for pure tool-call carriers).
          expect(streamed(['m3208']), '');
          expect(streamed(['m3208\nреальный ответ']), 'реальный ответ');
          // The decision survives a delta split too (no flicker).
          expect(streamed(['m320', '8\nготово']), 'готово');
        },
      );

      test(
        'a mid-message undecided tail survives verbatim (regex contract)',
        () {
          // No trailing space — `^m\d+ ` never matched, so the bytes are the
          // model's own words and must survive. Only the message's FIRST
          // line-start candidate is judged by the leading-alias rule.
          expect(streamed(['text\nm2']), 'text\nm2');
          expect(streamed(['ответ\nm1494']), 'ответ\nm1494');
        },
      );

      test('an alias-like opening that is not a tag passes through', () {
        // The `m3u8` lookahead rule (record_tag_echo.dart): digits followed
        // by a non-space are ordinary text.
        expect(streamed(['m3u8 ', 'stream']), 'm3u8 stream');
        expect(streamed(['m42x ', 'y']), 'm42x y');
      });

      test('a bare m is not a leading alias', () {
        // `^m\d+` needs a digit — a lone `m` is the model's own text.
        expect(streamed(['m', '\nx']), 'm\nx');
      });

      test(
        'a leading alias ends at any regex whitespace, not just a space',
        () {
          // The lookahead is `(?=\s|$)` — a tab or CR ends the alias the
          // same way a newline does; the seam's trimLeft then eats the run.
          expect(streamed(['m3208\tответ']), 'ответ');
          expect(streamed(['m3208\r\nготово']), 'готово');
        },
      );

      test(
        'after the stripped leading alias the per-line rule re-arms only at line starts',
        () {
          // The seam order: stripRecordTags runs BEFORE the leading alias +
          // trimLeft — so a byte at an ORIGINAL line boundary re-arms the
          // `^m\d+ +` rule, while a byte trimmed out of a mid-line position
          // does not (the seam's trimLeft already consumed it).
          expect(streamed(['m3208\nm1494 x']), 'x');
          expect(streamed(['m3208\n x']), 'x');
          expect(streamed(['m3208\nготово']), 'готово');
        },
      );

      test('a mid-message newline re-arms the classification', () {
        expect(streamed(['Принято\n', 'm1482 ', 'Жду PR']), 'Принято\nЖду PR');
      });

      test('a tagged line with multiple trailing spaces swallows them all', () {
        expect(streamed(['m7   spaced']), 'spaced');
      });

      test('flush resets — the next message classifies from a fresh line', () {
        final filter = RecordTagEchoStreamFilter();
        expect(filter.push('m1'), '');
        // `m1` opened the message: flush strips it as a leading alias
        // (`^m\d+(?=\s|$)` — the `$` lookahead), not verbatim.
        expect(filter.flush(), '');
        expect(filter.push('ok'), 'ok');
        expect(filter.flush(), '');
        // A new message's leading tag is recognized again after the reset.
        expect(filter.push('m1482 '), '');
        expect(filter.push('text'), 'text');
      });

      test('stripRecordTags and the stream filter agree on whole texts', () {
        const text = 'm1482 Один\nkeep m143 inline\nm9  [expand]\nm3u8 x\nm2';
        final filter = RecordTagEchoStreamFilter();
        var viaStream = filter.push(text);
        // A complete text ends without a trailing newline: an undecided
        // tail can only exist when the text ENDS inside `m\d+` — here `m2`
        // has no trailing space, so flush must keep it (the regex rule).
        viaStream += filter.flush();
        expect(viaStream, stripRecordTags(text));
      });

      test(
        'stripRecordTagEcho and the stream filter agree (gh-2412 parity)',
        () {
          // gh-2472 review: the current suite pinned parity with
          // `stripRecordTags` only — the leading-alias half of the gh-2412
          // contract lives in `stripRecordTagEcho` (the finalize seam), and
          // the live faces must render what the seam stores.
          const texts = [
            'm3208', // a reply that is ONLY its tag
            'm3208\nреальный ответ',
            'm3208\nm1494 x', // a tagged line after the stripped alias
            'm3208\n\n\n  отступ сохранён?',
            'm3208\r\nготово',
            'm1482 Один\nkeep m143 inline\nm9  [expand]\nm3u8 x\nm2',
            'm1482 Один\nm1494\nm1510 Два',
            'm3u8 stream',
            'm2\nm2',
            'ok\nm9\nx',
            '\n m3208', // the alias is anchored at the message start only
            'just text',
            '',
          ];
          for (final text in texts) {
            final filter = RecordTagEchoStreamFilter();
            final viaStream = filter.push(text) + filter.flush();
            final viaSeam = _seamStrippedText(text);
            expect(viaStream, viaSeam, reason: 'text: ${jsonEncode(text)}');
          }
        },
      );
    });
  });
}
