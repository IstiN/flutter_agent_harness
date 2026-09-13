/// Session image registry (issue #171) unit tests: content-keyed dedup,
/// first-seen index assignment, request-assembly rewrite (send-once +
/// `[Image N]` refs), cap priority, and dangling-ref resolution.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/markers.dart'
    show localTrimMarkerPrefix;
import 'package:flutter_agent_harness/src/session/session_tree.dart'
    show branchSummaryPrefix, branchSummarySuffix;
import 'package:test/test.dart';

ImageContent _img(String data, {String mimeType = 'image/png'}) =>
    ImageContent(data: data, mimeType: mimeType);

UserMessage _user(Object content, {int ms = 0}) => UserMessage(
  content: content,
  timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0, ms),
);

AssistantMessage _assistantText(String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

ToolCall _call(String id) =>
    ToolCall(id: id, name: 'snap', arguments: const {});

AssistantMessage _assistantCall(ToolCall call) => AssistantMessage(
  content: [call],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.toolUse,
  timestamp: DateTime.utc(2026),
);

ToolResultMessage _result(
  String callId,
  List<ContentBlock> content, {
  int ms = 0,
}) => ToolResultMessage(
  toolCallId: callId,
  toolName: 'snap',
  content: content,
  isError: false,
  timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0, ms),
);

int _imageCount(List<Message> messages) {
  var count = 0;
  for (final message in messages) {
    if (message is UserMessage && message.content is List<ContentBlock>) {
      count += (message.content as List<ContentBlock>)
          .whereType<ImageContent>()
          .length;
    } else if (message is ToolResultMessage) {
      count += message.content.whereType<ImageContent>().length;
    }
  }
  return count;
}

int _occurrences(String haystack, String needle) {
  var count = 0;
  for (
    var i = haystack.indexOf(needle);
    i != -1;
    i = haystack.indexOf(needle, i + needle.length)
  ) {
    count++;
  }
  return count;
}

String _serialized(List<Message> messages) =>
    jsonEncode([for (final m in messages) m.toJson()]);

void main() {
  group('ImageRegistry.scan', () {
    test('assigns one entry per unique payload in first-seen order', () {
      final registry = ImageRegistry.scan([
        _user([_img('aaa'), _img('bbb')]),
        _user([_img('aaa')]),
      ]);
      expect(registry.length, 2);
      expect(registry.indexByKey.values.toList()..sort(), [0, 1]);
    });

    test(
      'keys are content keys: same bytes different mime are distinct (E1)',
      () {
        final registry = ImageRegistry.scan([
          _user([_img('aaa', mimeType: 'image/png')]),
          _user([_img('aaa', mimeType: 'image/jpeg')]),
        ]);
        expect(registry.length, 2);
      },
    );

    test('tool-result images participate like user images (AC7)', () {
      final registry = ImageRegistry.scan([
        _result('c1', [_img('aaa')]),
        _user([_img('aaa')]),
        _result('c2', [_img('aaa')]),
      ]);
      expect(registry.length, 1);
    });

    test(
      'deterministic: two scans of one window build identical maps (AC2)',
      () {
        final messages = <Message>[
          _user([_img('aaa'), _img('bbb')]),
          _assistantText('looks good'),
          _result('c1', [_img('bbb')]),
          _user([_img('ccc')]),
        ];
        final first = ImageRegistry.scan(messages).indexByKey;
        // A JSONL round trip (the "load the file again" path) must rebuild
        // the same map.
        final reloaded = [
          for (final json in messages.map((m) => m.toJson()))
            messageFromJson(json),
        ];
        expect(ImageRegistry.scan(reloaded).indexByKey, first);
      },
    );
  });

  group('rewriteHistoryImages', () {
    test('image-free input returns the identical list instance', () {
      final messages = <Message>[_user('hello'), _assistantText('hi')];
      expect(identical(rewriteHistoryImages(messages), messages), isTrue);
    });

    test('same image in three messages rides once with text refs (AC1)', () {
      // The card's headline scenario: the user attached the same photo in
      // three messages — twice in history, once in the current message.
      final rewritten = rewriteHistoryImages([
        _user([_img('aaa')]),
        _user([_img('aaa')]),
        _user([TextContent(text: 'what did you see?'), _img('aaa')]),
      ]);
      // Exactly one image part rides — in the CURRENT message, in place.
      expect(_imageCount(rewritten), 1);
      final current = rewritten.last as UserMessage;
      expect(
        (current.content as List<ContentBlock>)
            .whereType<ImageContent>()
            .single
            .data,
        'aaa',
      );

      // Both history occurrences became text refs; the current image
      // carries its own label (F3) — one image payload, three [Image 0]
      // labels over the serialized request.
      final serialized = _serialized(rewritten);
      expect(_occurrences(serialized, 'aaa'), 1);
      expect(_occurrences(serialized, '[Image 0]'), 3);
      expect(_occurrences(serialized, unavailableImageNote), 0);
    });

    test('all-history image rides in a carrier before the first ref', () {
      final rewritten = rewriteHistoryImages([
        _user([_img('aaa')]),
        _user([_img('aaa')]),
        _user([_img('aaa')]),
        _user('what did you see?'),
      ]);
      // Exactly one image part rides — in a dedicated carrier message.
      expect(_imageCount(rewritten), 1);
      final carrier = rewritten.whereType<UserMessage>().firstWhere(
        (m) =>
            m.content is List<ContentBlock> &&
            (m.content as List<ContentBlock>).any((b) => b is ImageContent),
      );
      final blocks = carrier.content as List<ContentBlock>;
      expect(blocks, hasLength(2));
      expect((blocks[0] as TextContent).text, '[Image 0]');
      expect(blocks[1], isA<ImageContent>());

      // The carrier is inserted before the FIRST referencing message;
      // every occurrence became a ref (carrier label + three refs).
      expect(rewritten.indexOf(carrier), 0);
      final serialized = _serialized(rewritten);
      expect(_occurrences(serialized, 'aaa'), 1);
      expect(_occurrences(serialized, '[Image 0]'), 4);
    });

    test('current message images ride in place, never referenced (AC6/I3)', () {
      final current = _user([TextContent(text: 'this again'), _img('aaa')]);
      final rewritten = rewriteHistoryImages([
        _user([_img('aaa')]),
        _assistantText('nice'),
        current,
      ]);
      expect(_imageCount(rewritten), 1);
      // The current message keeps the image in place, now with its
      // `[Image N]` label preceding it (F3).
      final outCurrent = rewritten.last as UserMessage;
      final outBlocks = outCurrent.content as List<ContentBlock>;
      expect(outBlocks, hasLength(3));
      expect((outBlocks[0] as TextContent).text, 'this again');
      expect((outBlocks[1] as TextContent).text, '[Image 0]');
      expect(outBlocks[2], isA<ImageContent>());

      // The history occurrence became a text ref; no carrier was added
      // (the original rides in the current message) — I4 holds.
      final first = rewritten[0] as UserMessage;
      final firstBlock = (first.content as List<ContentBlock>).single;
      expect((firstBlock as TextContent).text, '[Image 0]');
      expect(rewritten, hasLength(3));
    });

    test('carrier lands after a tool-result run, never inside it', () {
      final call = _call('c1');
      final rewritten = rewriteHistoryImages([
        _user('screenshot the page'),
        _assistantCall(call),
        _result('c1', [TextContent(text: 'shot'), _img('shot')]),
        _assistantText('done'),
      ]);
      // The carrier is after the tool result (wire safety: nothing may sit
      // between a tool call and its result) and pairing stays valid.
      final carrierIndex = rewritten.indexWhere(
        (m) =>
            m is UserMessage &&
            m.content is List<ContentBlock> &&
            (m.content as List<ContentBlock>).any((b) => b is ImageContent),
      );
      expect(carrierIndex, 3); // after the tool result, before 'done'
      expect(validateToolPairing(rewritten), isEmpty);
    });

    test('cap: current first, then newest; drops carry key previews (AC3)', () {
      // 10 uniques: history messages carry images 0..8 (8 = newest
      // history), the current message carries image 9.
      final messages = <Message>[
        for (var i = 0; i <= 8; i++) _user([_img('img$i')], ms: i),
        _user([_img('img9')], ms: 9),
      ];
      final drops = <(int, String)>[];
      final rewritten = rewriteHistoryImages(
        messages,
        maxPerRequest: 4,
        onDrop: (index, preview) => drops.add((index, preview)),
      );
      // 4 ride: the current one plus the 3 newest history images.
      expect(_imageCount(rewritten), 4);
      final serialized = _serialized(rewritten);
      for (final riding in ['img9', 'img8', 'img7', 'img6']) {
        expect(_occurrences(serialized, riding), 1);
      }
      // No dropped original rides.
      for (var i = 0; i <= 5; i++) {
        expect(_occurrences(serialized, 'img$i'), 0);
      }
      // Every drop is reported with a key preview (never silent).
      expect(drops.map((d) => d.$1).toSet(), {0, 1, 2, 3, 4, 5});
      for (final (_, preview) in drops) {
        expect(preview, matches(r'^[0-9a-f]{8}'));
      }
      // Dropped occurrences resolve to the unavailable note.
      expect(_occurrences(serialized, unavailableImageNote), 6);
    });

    test(
      'E2: one slot left among same-message images rides the first-seen',
      () {
        final rewritten = rewriteHistoryImages([
          _user([_img('x1'), _img('x2'), _img('x3')]),
          _user('current'),
        ], maxPerRequest: 1);
        expect(_imageCount(rewritten), 1);
        final serialized = _serialized(rewritten);
        expect(_occurrences(serialized, 'x1'), 1);
        expect(_occurrences(serialized, unavailableImageNote), 2);
      },
    );

    test('stale mention in a summary resolves to the note (AC4/I4)', () {
      final rewritten = rewriteHistoryImages([
        _user('Summary: the user shared [Image 3] earlier.'),
        _user('continue'),
      ]);
      final serialized = _serialized(rewritten);
      expect(_occurrences(serialized, '[Image 3]'), 0);
      expect(_occurrences(serialized, unavailableImageNote), 1);
    });

    test('mention of a riding image stays intact (I4)', () {
      final rewritten = rewriteHistoryImages([
        _user([_img('aaa'), TextContent(text: 'see also [Image 0]')]),
        _user('current'),
      ]);
      // Carrier label + rewritten block ref + the preserved mention.
      expect(_occurrences(_serialized(rewritten), '[Image 0]'), 3);
    });

    test('assistant citations of dropped images resolve to the note', () {
      final rewritten = rewriteHistoryImages([
        _user([_img('a1'), _img('a2')]),
        _assistantText('as shown in [Image 1]'),
        _user([_img('a1')], ms: 2),
        _user('current'),
      ], maxPerRequest: 1);
      final serialized = _serialized(rewritten);
      // Image 1 (a2) is the older history image — dropped by the cap of 1.
      expect(_occurrences(serialized, '[Image 1]'), 0);
      expect(_occurrences(serialized, unavailableImageNote), greaterThan(0));
    });

    test('no dangling refs: every surviving label has its original (I4)', () {
      final rewritten = rewriteHistoryImages([
        _user([_img('imga'), _img('imgb'), _img('imgc')]),
        _assistantText('comparing [Image 0] and [Image 2]'),
        _user([_img('imgb')]),
        _user('current'),
      ], maxPerRequest: 2);
      // current has no images → 2 history slots; by recency b rides over
      // a (b's last occurrence is newer), then a (first-seen tie-break);
      // c drops.
      final serialized = _serialized(rewritten);
      expect(_imageCount(rewritten), 2);
      expect(_occurrences(serialized, 'imga'), 1);
      expect(_occurrences(serialized, 'imgb'), 1);
      expect(_occurrences(serialized, 'imgc'), 0);
      // [Image 0] = a: carrier + block ref + assistant citation.
      expect(_occurrences(serialized, '[Image 0]'), 3);
      // [Image 1] = b: carrier + block ref + second-occurrence ref.
      expect(_occurrences(serialized, '[Image 1]'), 3);
      // [Image 2] = c: dropped → its block and the assistant citation both
      // resolve to the note.
      expect(_occurrences(serialized, '[Image 2]'), 0);
      expect(_occurrences(serialized, unavailableImageNote), 2);
    });
  });

  group('renumbering boundaries: stale citations degrade (issue #195 F2)', () {
    UserMessage summaryMarker({int ms = 0}) => UserMessage.text(
      '${compactionSummaryPrefix}old history$compactionSummarySuffix',
      timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0, ms),
    );

    String assistantText(List<Message> messages) =>
        (messages
                .whereType<AssistantMessage>()
                .single
                .content
                .whereType<TextContent>()
                .single)
            .text;

    String lastAssistantText(List<Message> messages) =>
        (messages.whereType<AssistantMessage>().last.content
                .whereType<TextContent>()
                .single)
            .text;

    test('a stale citation degrades instead of rebinding to the wrong '
        'image', () {
      // Pre-compaction the window held a(0), b(1); the citation named b.
      // Compaction evicts a and c arrives — renumbering makes 1 = c.
      final rewritten = rewriteHistoryImages([
        summaryMarker(ms: 10),
        _user([_img('bbb')], ms: 1),
        _assistantText('about [Image 1]'),
        _user([TextContent(text: 'new one'), _img('ccc')], ms: 20),
      ]);
      // The citation never passes through as a number: it would make the
      // model quote b while seeing c.
      expect(assistantText(rewritten), contains(unavailableImageNote));
      // b and c still ride: the carrier for b and the in-place current c.
      expect(_imageCount(rewritten), 2);
      expect(_serialized(rewritten), contains('[Image 0]'));
    });

    test('fresh citations survive when the window was never renumbered', () {
      final rewritten = rewriteHistoryImages([
        _user([_img('aaa')], ms: 1),
        _user([_img('bbb')], ms: 2),
        _assistantText('about [Image 1]'),
        _user('go on', ms: 3),
      ]);
      expect(assistantText(rewritten), contains('[Image 1]'));
    });

    test('structured hidden/checkpoint markers open the stale epoch too', () {
      for (final marker in <String>[
        '[3:hidden·user·12]',
        '[2-6:ckpt·38k→40tok·covers:3,5]',
      ]) {
        final rewritten = rewriteHistoryImages([
          _user([_img('aaa')], ms: 1),
          _user([_img('bbb')], ms: 2),
          UserMessage.text(
            marker,
            timestamp: DateTime.utc(2026, 1, 1, 0, 0, 1),
          ),
          _assistantText('about [Image 1]'),
          _user('go on', ms: 3),
        ]);
        expect(
          assistantText(rewritten),
          contains(unavailableImageNote),
          reason: 'marker "$marker" must degrade stale citations',
        );
      }
    });

    test('a hidden tool_result marker (visible call) opens the stale '
        'epoch too', () {
      final rewritten = rewriteHistoryImages([
        _user([_img('bbb')], ms: 1),
        _assistantCall(_call('c9')),
        _result('c9', [TextContent(text: '[3:hidden·tool_result·4.2k]')]),
        _assistantText('about [Image 0]'),
        _user('go on', ms: 3),
      ]);
      // [Image 0] rides (bbb holds it now), but the citation was authored
      // before the structured hide renumbered the window — degrade it.
      expect(lastAssistantText(rewritten), contains(unavailableImageNote),
          reason: 'structured hide without checkpoint must degrade');
    });

    test('a branch summary marker opens the stale epoch too', () {
      final rewritten = rewriteHistoryImages([
        _user([_img('bbb')], ms: 1),
        UserMessage.text(
          '${branchSummaryPrefix}branch summary$branchSummarySuffix',
          timestamp: DateTime.utc(2026, 1, 1, 0, 0, 1),
        ),
        _assistantText('about [Image 0]'),
        _user('go on', ms: 3),
      ]);
      expect(lastAssistantText(rewritten), contains(unavailableImageNote),
          reason: 'branch summary must degrade stale citations');
    });

    test('the local trim valve marker does too', () {
      final rewritten = rewriteHistoryImages([
        UserMessage.text(
          "$localTrimMarkerPrefix the valve note'",
          timestamp: DateTime.utc(2026, 1, 1, 0, 0, 1),
        ),
        _user([_img('aaa')], ms: 1),
        _user([_img('bbb')], ms: 2),
        _assistantText('about [Image 1]'),
        _user('go on', ms: 3),
      ]);
      expect(assistantText(rewritten), contains(unavailableImageNote));
    });

    test('current-message citations stay trusted after compaction', () {
      final rewritten = rewriteHistoryImages([
        summaryMarker(ms: 0),
        _user([_img('aaa')], ms: 1),
        _user([_img('bbb')], ms: 2),
        _user('compare with [Image 1] please', ms: 3),
      ]);
      final current = rewritten.whereType<UserMessage>().last;
      expect(current.content, contains('[Image 1]'));
    });
  });

  group('current-message labels (issue #195 F3)', () {
    test('in-place current images carry their [Image N] label', () {
      final rewritten = rewriteHistoryImages([
        _user([_img('aaa')], ms: 1),
        _user([TextContent(text: 'and this'), _img('bbb')], ms: 2),
      ]);
      final current = rewritten.whereType<UserMessage>().last;
      final blocks = current.content as List<ContentBlock>;
      expect(blocks, hasLength(3));
      expect((blocks[0] as TextContent).text, 'and this');
      // The image keeps riding in place; the label precedes it.
      expect((blocks[1] as TextContent).text, '[Image 1]');
      expect(blocks[2], isA<ImageContent>());
    });

    test('a string-only current message is left alone', () {
      final rewritten = rewriteHistoryImages([
        _user([_img('aaa')], ms: 1),
        _user('plain text', ms: 2),
      ]);
      final current = rewritten.whereType<UserMessage>().last;
      expect(current.content, 'plain text');
    });
  });
}
