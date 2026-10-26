/// Session image registry (issue #171) unit tests: content-keyed dedup,
/// first-seen index assignment, request-assembly rewrite (send-once +
/// `[Image N]` refs), cap priority, and dangling-ref resolution.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/markers.dart'
    show localTrimMarkerPrefix;
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
      final drops = <ImageDropEvent>[];
      final rewritten = rewriteHistoryImages(
        messages,
        maxPerRequest: 4,
        modelId: 'test-model',
        onReport: (report) => drops.addAll(report.drops),
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
      // Every drop is reported with a key preview (never silent), and
      // all of them are history drops (the current batch rode).
      expect(drops.map((d) => d.index).toSet(), {0, 1, 2, 3, 4, 5});
      expect(drops.map((d) => d.fromCurrentMessage), everyElement(isFalse));
      for (final drop in drops) {
        expect(drop.keyPreview, matches(r'^[0-9a-f]{8}'));
      }
      // Dropped occurrences resolve to the unavailable note.
      expect(_occurrences(serialized, unavailableImageNote), 6);
    });

    test('the cap applies to the current batch too (#1889 R2/AC3)', () {
      // 25 just-attached images in the current message, cap 20: the
      // first-seen 20 ride in place, the 5 extras drop as CURRENT-message
      // drops — the actionable case the prominent warning reports.
      // Payloads are zero-padded: no name is a prefix of another, so the
      // serialized-occurrence counts below stay exact.
      String payload(int i) => 'batch${i.toString().padLeft(2, '0')}';
      final messages = <Message>[
        _assistantText('send them'),
        _user([for (var i = 0; i < 25; i++) _img(payload(i))]),
      ];
      final reports = <ImageDropReport>[];
      final rewritten = rewriteHistoryImages(
        messages,
        maxPerRequest: 20,
        onReport: reports.add,
      );
      expect(_imageCount(rewritten), 20);
      final report = reports.single;
      expect(report.drops, hasLength(5));
      expect(
        report.drops.map((d) => d.fromCurrentMessage),
        everyElement(isTrue),
      );
      expect(report.currentImageCount, 25);
      // First-seen wins inside the batch: batch00..batch19 ride.
      final serialized = _serialized(rewritten);
      for (var i = 0; i < 25; i++) {
        expect(
          _occurrences(serialized, payload(i)),
          i < 20 ? 1 : 0,
          reason: 'payload ${payload(i)}',
        );
      }
      expect(_occurrences(serialized, unavailableImageNote), 5);
    });

    test('a current-dropped key never also rides from history (#1889)', () {
      // The same content sits in the over-cap current message AND in an
      // older history message: the current drop must not silently re-enter
      // through the history path.
      final messages = <Message>[
        _user([_img('dup0'), _img('dup1'), _img('dup2')]),
        _assistantText('ok'),
        _user([for (var i = 0; i < 25; i++) _img(i < 3 ? 'dup$i' : 'new$i')]),
      ];
      final reports = <ImageDropReport>[];
      rewriteHistoryImages(messages, maxPerRequest: 20, onReport: reports.add);
      final report = reports.single;
      // 5 current drops (dup0, dup1, dup2 among them by first-seen); the
      // dropped keys never appear on the history side.
      expect(report.drops.where((d) => d.fromCurrentMessage), hasLength(5));
      expect(report.drops.where((d) => !d.fromCurrentMessage), isEmpty);
      expect(report.ridingCount, 20);
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
        (messages
                .whereType<AssistantMessage>()
                .last
                .content
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
      expect(
        lastAssistantText(rewritten),
        contains(unavailableImageNote),
        reason: 'structured hide without checkpoint must degrade',
      );
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
      expect(
        lastAssistantText(rewritten),
        contains(unavailableImageNote),
        reason: 'branch summary must degrade stale citations',
      );
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

  group('per-model image caps (issue #1750)', () {
    const globalDefault = 20;
    setUp(() {
      imageRegistryConfig = const ImageRegistryConfig(
        maxPerRequest: globalDefault,
      );
    });
    tearDown(() {
      imageRegistryConfig = const ImageRegistryConfig();
    });

    test('AC2: resolution matrix — perModel > catalog > default', () {
      int resolve({
        String? modelId,
        int? catalog,
        Map<String, int>? perModel,
      }) => resolveImageCap(
        modelId: modelId,
        catalogMaxImages: catalog,
        perModel: perModel,
      );
      // All three layers present: the first wins.
      expect(resolve(modelId: 'm', catalog: 10, perModel: {'m': 4}), 4);
      // perModel present, catalog absent.
      expect(resolve(modelId: 'm', perModel: {'m': 4}), 4);
      // perModel absent, catalog present.
      expect(resolve(modelId: 'm', catalog: 10), 10);
      // Only the default.
      expect(resolve(modelId: 'm'), globalDefault);
      expect(resolve(), globalDefault);
      // perModel keyed for ANOTHER model never leaks (catalog wins).
      expect(resolve(modelId: 'm', catalog: 10, perModel: {'other': 4}), 10);
      // A perModel value below the default is honored (ceiling-setter).
      expect(
        resolve(modelId: 'gemini-4-argon', perModel: {'gemini-4-argon': 2}),
        2,
      );
    });

    test('the catalog seed names gemini-4-argon: 10', () {
      expect(catalogMaxImages['gemini-4-argon'], 10);
    });

    test('AC1: a model with a perModel cap rides ≤ cap uniques', () {
      // 6 uniques; the config caps this model at 3.
      final messages = [
        for (var i = 0; i < 5; i++) _user([_img('img$i')], ms: i),
        _user([_img('img5')], ms: 5),
      ];
      final drops = <int>[];
      final cap = resolveImageCap(
        modelId: 'gemini-4-argon',
        perModel: const {'gemini-4-argon': 3},
      );
      final rewritten = rewriteHistoryImages(
        messages,
        maxPerRequest: cap,
        onReport: (report) => drops.addAll(report.drops.map((d) => d.index)),
      );
      expect(_imageCount(rewritten), 3);
      expect(drops, hasLength(3));
      // Current-first-then-newest: the current img5 plus img4, img3 ride.
      final serialized = _serialized(rewritten);
      for (final riding in ['img5', 'img4', 'img3']) {
        expect(_occurrences(serialized, riding), 1);
      }
      for (var i = 0; i <= 2; i++) {
        expect(_occurrences(serialized, 'img$i'), 0);
      }
    });

    test('imageCapLatchKey is scoped per (provider, model) pair (E2)', () {
      expect(
        imageCapLatchKey('copilot', 'gemini-4-argon'),
        'copilot|gemini-4-argon',
      );
      expect(
        imageCapLatchKey('copilot', 'other'),
        isNot(imageCapLatchKey('copilot', 'gemini-4-argon')),
      );
    });
  });

  group('#1916: per-request image byte budget', () {
    // Sizes in base64 chars — ImageContent.data.length IS the wire size.
    ImageDropReport? rewrite(List<Message> messages, {int? cap, int? bytes}) {
      ImageDropReport? report;
      rewriteHistoryImages(
        messages,
        maxPerRequest: cap,
        maxBytesPerRequest: bytes,
        onReport: (r) => report = r,
      );
      return report;
    }

    test('AC1: the byte budget drops oldest history first, reason bytes', () {
      // Current image rides first (3 chars), history newest-first is
      // img-new (3), img-mid (3), img-old (3); budget 8 leaves 5 for
      // history → img-new rides (2 left), the rest drop as byte drops.
      final messages = <Message>[
        _user([_img('old')]),
        _user([_img('mid')]),
        _user([_img('new')]),
        _user('current now'),
        _user([_img('curr')]),
      ];
      final report = rewrite(messages, cap: 20, bytes: 8)!;
      expect(report.registryCount, 4);
      expect(report.ridingCount, 2); // current + newest history
      expect(report.maxBytes, 8);
      final byteDrops = report.drops
          .where((d) => d.reason == ImageDropReason.bytes)
          .toList();
      expect(byteDrops, hasLength(2));
      expect(
        byteDrops.every((d) => d.fromCurrentMessage == false),
        isTrue,
        reason: 'current fits the budget; only history overflows',
      );
      // Drop order stays newest-first-then-older (current never drops here).
      expect(byteDrops[0].key, imageContentKey(_img('mid')));
      expect(byteDrops[1].key, imageContentKey(_img('old')));
    });

    test('AC1: a byte drop never stops the scan — a smaller older image '
        'still fits (greedy pass)', () {
      // Recency order (newest history first): 8 chars, 6 chars, 2 chars.
      // Budget 10: 8 rides (leaving 2), 6 overflows (byte drop), the scan
      // CONTINUES and the 2-char image rides. A stop-at-first-overflow
      // policy would have dropped the 2-char image instead.
      final messages = <Message>[
        _user([_img('12')]), // 2 chars, oldest message
        _user([_img('123456')]), // 6 chars
        _user([_img('12345678')]), // 8 chars, newest history
        _user('look'),
      ];
      final report = rewrite(messages, cap: 20, bytes: 10)!;
      expect(report.ridingCount, 2); // 8-char + 2-char
      expect(report.drops, hasLength(1));
      expect(report.drops.single.reason, ImageDropReason.bytes);
      expect(report.drops.single.key, imageContentKey(_img('123456')));
    });

    test('AC1: the count cap and the byte budget both name their reason', () {
      final messages = <Message>[
        _user([_img('aa')]),
        _user([_img('bb')]),
        _user([_img('cc')]),
        _user('now'),
      ];
      // cap 2, bytes 0 (off): exactly one count drop.
      final countOnly = rewrite(messages, cap: 2, bytes: 0)!;
      expect(countOnly.drops, hasLength(1));
      expect(countOnly.drops.single.reason, ImageDropReason.count);
      // cap 20, bytes 3: two byte drops (only the newest 2-char image
      // fits — the second 2-char image would exhaust what's left).
      final byteOnly = rewrite(messages, cap: 20, bytes: 3)!;
      expect(byteOnly.drops, hasLength(2));
      expect(
        byteOnly.drops.every((d) => d.reason == ImageDropReason.bytes),
        isTrue,
      );
    });

    test('AC1: an over-budget current image drops as a current byte drop', () {
      final messages = <Message>[
        _user('selfie time'),
        _user([_img('12345678'), _img('87654321')]),
      ];
      final report = rewrite(messages, cap: 20, bytes: 10)!;
      expect(report.drops, hasLength(1));
      expect(report.drops.single.fromCurrentMessage, isTrue);
      expect(report.drops.single.reason, ImageDropReason.bytes);
      expect(report.ridingCount, 1);
    });

    test('AC1: report carries the budget; 0 keeps #1889 surfaces quiet', () {
      final messages = <Message>[
        _user('hi'),
        _user([_img('aa')]),
      ];
      expect(rewrite(messages, cap: 5, bytes: 123)!.maxBytes, 123);
      // The #1889 constructor shape (no maxBytes) still reports 0.
      const legacy = ImageDropReport(
        drops: [],
        cap: 20,
        modelId: 'm',
        currentImageCount: 0,
        registryCount: 0,
        ridingCount: 0,
      );
      expect(legacy.maxBytes, 0);
    });
  });

  group('#1916: legacy text-embedded images fold into the registry (AC2)', () {
    // Just over the 64KB floor — small enough for a fast test, big enough
    // to prove the floor gate. The session's real blobs were ~1.3MB.
    final blob = 'Q' * 70000;
    final blob2 = 'R' * 70000;
    String dataUrl(String payload) => 'data:image/png;base64,$payload';

    int outboundImageBytes(List<Message> messages) {
      var bytes = 0;
      for (final message in messages) {
        final blocks = switch (message) {
          UserMessage(:final content) when content is List<ContentBlock> =>
            content,
          ToolResultMessage(:final content) => content,
          _ => null,
        };
        if (blocks == null) continue;
        for (final block in blocks) {
          if (block is ImageContent) bytes += block.data.length;
        }
      }
      return bytes;
    }

    test('AC2: the request-590 shape — 9 history text screenshots, one '
        'registered block — folds and never replays raw', () {
      // Two identical history screenshots as TEXT (the evidence shape:
      // raw base64 in user messages, nothing registered), one distinct
      // history screenshot, and a current message with a real block.
      final url = dataUrl(blob);
      final messages = <Message>[
        _user('look: ![]($url)'),
        _assistantText('noted'),
        _user('again: ![]($url)'),
        _assistantText('ok'),
        _user('different one: ${dataUrl(blob2)}'),
        _assistantText('seen'),
        _user('and now the current one'),
        _user([_img('abc')]),
      ];
      final before = outboundImageBytes(messages);
      ImageDropReport? report;
      final out = rewriteHistoryImages(messages, onReport: (r) => report = r);
      // BEFORE: 3 chars of ImageContent (the 'abc' block) — the 210000
      // chars of text-embedded base64 were invisible to the registry and
      // replayed on every request. AFTER: the two identical screenshots
      // dedup to ONE carrier, the distinct one rides as a second, and no
      // raw data URL survives anywhere in the payload.
      expect(before, 3);
      expect(outboundImageBytes(out), 140003);
      final serialized = _serialized(out);
      expect(serialized.contains(url), isFalse);
      expect(serialized.contains(dataUrl(blob2)), isFalse);
      expect(report!.registryCount, 3); // deduped screenshot + distinct + abc
      // Both text occurrences became refs to the deduped carrier.
      expect(
        _occurrences(serialized, '[Image 0]'),
        2 + 1,
        reason: 'two refs plus the carrier label',
      );
    });

    test('AC2: the current message keeps its text data URL verbatim (I3)', () {
      final url = dataUrl(blob);
      final messages = <Message>[
        _user('earlier'),
        _user('current paste: $url'),
      ];
      final out = rewriteHistoryImages(messages);
      final current = out.last as UserMessage;
      expect(current.content, 'current paste: $url');
    });

    test('AC2: small text data URLs stay text (icons are legitimate)', () {
      const icon = 'iVBORw0KGgo=';
      final messages = <Message>[_user('icon: ${dataUrl(icon)}'), _user('now')];
      expect(identical(rewriteHistoryImages(messages), messages), isTrue);
    });

    test('AC2: tool-result text data URLs fold too', () {
      final messages = <Message>[
        _assistantCall(_call('c1')),
        _result('c1', [TextContent(text: 'shot: ${dataUrl(blob)}')]),
        _user('now'),
      ];
      final out = rewriteHistoryImages(messages);
      expect(outboundImageBytes(out), 70000);
      final serialized = _serialized(out);
      expect(serialized.contains(dataUrl(blob)), isFalse);
      expect(
        _occurrences(serialized, '[Image 0]'),
        2,
        reason: 'the folded ref plus the carrier label',
      );
    });

    test('AC2: surrounding text survives the fold (split at URL edges)', () {
      final messages = <Message>[
        _user('before ${dataUrl(blob)} after'),
        _user('now'),
      ];
      final out = rewriteHistoryImages(messages);
      final texts = [
        for (final message in out)
          if (message is UserMessage && message.content is List<ContentBlock>)
            for (final block in message.content as List<ContentBlock>)
              if (block is TextContent) block.text,
      ];
      expect(texts.any((t) => t.contains('before')), isTrue);
      expect(texts.any((t) => t.contains('after')), isTrue);
    });

    test('AC2: image-free fast path still returns the caller instance', () {
      final messages = <Message>[_user('hello'), _assistantText('hi')];
      expect(identical(rewriteHistoryImages(messages), messages), isTrue);
    });
  });
}
