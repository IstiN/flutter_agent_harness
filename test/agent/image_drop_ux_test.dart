/// The aggregated, latched image-drop notice layer (issue #1889).
///
/// AC1: the 37-images-cap-20 flood collapses to ONE notice over any
/// number of identical requests while every per-image event stays in the
/// report (the debug surface's feed). AC2: latch transitions — changed
/// set, recovery, same-set-after-compaction silence. AC3: the
/// current-batch prominent warning vs the low-key history line. AC4: the
/// shared projection (`imageSurfaceLines`) both hosts render.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A report like the rewrite's: [historyDrops] history drops over
/// [registry] window images at [cap], for [model].
ImageDropReport historyDropReport({
  required int historyDrops,
  required int registry,
  int cap = 20,
  String model = 'test-model',
  List<String>? keys,
}) => ImageDropReport(
  drops: [
    for (var i = 0; i < historyDrops; i++)
      ImageDropEvent(
        index: i,
        key: keys == null ? 'hist-key-$i' : keys[i],
        fromCurrentMessage: false,
      ),
  ],
  cap: cap,
  modelId: model,
  currentImageCount: 0,
  registryCount: registry,
  ridingCount: registry - historyDrops,
);

void main() {
  group('AC1 — the flood collapses to one notice', () {
    test('37 window images, cap 20, 5 requests ⇒ exactly one notice', () {
      final ux = ImageDropUx();
      final notices = <ImageDropNoticeView?>[];
      for (var request = 0; request < 5; request++) {
        // Every request rebuilds the registry statelessly and drops the
        // same 17 history images (content keys stable across requests).
        notices.add(
          ux.observe(historyDropReport(historyDrops: 17, registry: 37)),
        );
      }
      final shown = notices.whereType<ImageDropNoticeView>().toList();
      expect(shown, hasLength(1));
      expect(shown.single.prominent, isFalse);
      expect(shown.single.line, contains('17 older images not sent'));
      expect(shown.single.line, contains('(cap 20)'));
      expect(shown.single.line, contains('/images for details'));
    });

    test('the same flood keeps every per-image event in the report', () {
      final ux = ImageDropUx();
      for (var request = 0; request < 5; request++) {
        final report = historyDropReport(historyDrops: 17, registry: 37);
        ux.observe(report);
        // Never silent at the debug surface: each request's report still
        // carries all 17 per-image drops (fa.log / AppLog feed).
        expect(report.drops, hasLength(17));
      }
    });

    test('per-request [Image N] labels do NOT defeat the latch', () {
      final ux = ImageDropUx();
      // Same content keys, DIFFERENT label indexes (a post-compaction
      // renumber): the situation is unchanged for the user — silence.
      ux.observe(
        ImageDropReport(
          drops: const [
            ImageDropEvent(index: 0, key: 'a', fromCurrentMessage: false),
            ImageDropEvent(index: 1, key: 'b', fromCurrentMessage: false),
          ],
          cap: 20,
          modelId: 'm',
          currentImageCount: 0,
          registryCount: 22,
          ridingCount: 20,
        ),
      );
      final second = ux.observe(
        ImageDropReport(
          drops: const [
            ImageDropEvent(index: 5, key: 'a', fromCurrentMessage: false),
            ImageDropEvent(index: 9, key: 'b', fromCurrentMessage: false),
          ],
          cap: 20,
          modelId: 'm',
          currentImageCount: 0,
          registryCount: 22,
          ridingCount: 20,
        ),
      );
      expect(second, isNull);
    });
  });

  group('AC2 — latch transitions', () {
    test('a changed dropped set ⇒ one new notice', () {
      final ux = ImageDropUx();
      ux.observe(historyDropReport(historyDrops: 17, registry: 37));
      final changed = ux.observe(
        historyDropReport(historyDrops: 18, registry: 38),
      );
      expect(changed, isNotNull);
      expect(changed!.line, contains('18 older images'));
      // …and exactly one: the next identical request is silence.
      expect(
        ux.observe(historyDropReport(historyDrops: 18, registry: 38)),
        isNull,
      );
    });

    test('recovery ⇒ one all-clear, then silence', () {
      final ux = ImageDropUx();
      ux.observe(historyDropReport(historyDrops: 17, registry: 37));
      final clear = ux.observe(
        historyDropReport(historyDrops: 0, registry: 20),
      );
      expect(clear, isNotNull);
      expect(clear!.line, contains('caught up'));
      expect(clear.prominent, isFalse);
      expect(
        ux.observe(historyDropReport(historyDrops: 0, registry: 20)),
        isNull,
      );
    });

    test('the all-clear names the now-riding count and cap', () {
      final ux = ImageDropUx();
      ux.observe(historyDropReport(historyDrops: 5, registry: 25));
      final clear = ux.observe(
        historyDropReport(historyDrops: 0, registry: 25),
      );
      expect(clear!.line, contains('all 25 window images sent (cap 20)'));
    });

    test('a cap raise is a new situation (new notice with the new cap)', () {
      final ux = ImageDropUx();
      ux.observe(historyDropReport(historyDrops: 17, registry: 37, cap: 20));
      final raised = ux.observe(
        historyDropReport(historyDrops: 17, registry: 37, cap: 40),
      );
      expect(raised, isNotNull);
      expect(raised!.line, contains('(cap 40)'));
    });

    test('a learned-cap change re-notices (#1750 interplay)', () {
      final ux = ImageDropUx();
      ux.observe(historyDropReport(historyDrops: 3, registry: 23, cap: 20));
      final learned = ux.observe(
        historyDropReport(historyDrops: 13, registry: 23, cap: 10, model: 'm'),
      );
      expect(learned, isNotNull);
      expect(learned!.line, contains('cap 10'));
    });

    test('same set after compaction (renumbered labels) ⇒ no repeat', () {
      final ux = ImageDropUx();
      ux.observe(
        historyDropReport(
          historyDrops: 17,
          registry: 37,
          keys: [for (var i = 0; i < 17; i++) 'content-$i'],
        ),
      );
      // Compaction evicted nothing image-bearing; labels renumbered but
      // the same content keys still over-cap.
      final after = ux.observe(
        historyDropReport(
          historyDrops: 17,
          registry: 37,
          keys: [for (var i = 100; i < 117; i++) 'content-${i - 100}'],
        ),
      );
      expect(after, isNull);
    });

    test('a different model id re-notices (latch is per model)', () {
      final ux = ImageDropUx();
      ux.observe(
        historyDropReport(historyDrops: 17, registry: 37, model: 'model-a'),
      );
      final other = ux.observe(
        historyDropReport(historyDrops: 17, registry: 37, model: 'model-b'),
      );
      expect(other, isNotNull);
    });

    test('reset re-latches from the first post-reset request (R4)', () {
      final ux = ImageDropUx();
      ux.observe(historyDropReport(historyDrops: 17, registry: 37));
      ux.reset();
      expect(ux.lastReport, isNull, reason: 'reset clears the surface');
      final first = ux.observe(
        historyDropReport(historyDrops: 17, registry: 37),
      );
      expect(first, isNotNull, reason: 'a fresh session re-latches once');
      expect(
        ux.observe(historyDropReport(historyDrops: 17, registry: 37)),
        isNull,
      );
    });
  });

  group('AC3 — severity split', () {
    ImageDropReport currentDropReport({
      required int currentDrops,
      required int currentTotal,
      int historyDrops = 0,
    }) => ImageDropReport(
      drops: [
        for (var i = 0; i < currentDrops; i++)
          ImageDropEvent(index: i, key: 'cur-$i', fromCurrentMessage: true),
        for (var i = 0; i < historyDrops; i++)
          ImageDropEvent(
            index: 100 + i,
            key: 'hist-$i',
            fromCurrentMessage: false,
          ),
      ],
      cap: 20,
      modelId: 'm',
      currentImageCount: currentTotal,
      registryCount: currentTotal + historyDrops,
      ridingCount: 20,
    );

    test(
      '25 attached, cap 20 ⇒ one prominent warning naming counts+remedy',
      () {
        final ux = ImageDropUx();
        final notice = ux.observe(
          currentDropReport(currentDrops: 5, currentTotal: 25),
        );
        expect(notice, isNotNull);
        expect(notice!.prominent, isTrue);
        expect(notice.line, contains('5 of 25 attached images'));
        expect(notice.line, contains('cap is 20/request'));
        expect(notice.line, contains('images.maxPerRequest'));
      },
    );

    test('repeated identical turns do not re-warn', () {
      final ux = ImageDropUx();
      ux.observe(currentDropReport(currentDrops: 5, currentTotal: 25));
      expect(
        ux.observe(currentDropReport(currentDrops: 5, currentTotal: 25)),
        isNull,
      );
    });

    test('history-only drops never produce the prominent variant', () {
      final ux = ImageDropUx();
      final notice = ux.observe(
        historyDropReport(historyDrops: 17, registry: 37),
      );
      expect(notice!.prominent, isFalse);
    });

    test('mixed current + history drops: prominent, both counts named', () {
      final ux = ImageDropUx();
      final notice = ux.observe(
        currentDropReport(currentDrops: 3, currentTotal: 23, historyDrops: 4),
      );
      expect(notice!.prominent, isTrue);
      expect(notice.line, contains('3 of 23 attached images'));
      expect(notice.line, contains('+4 older images'));
    });

    test('current-drop recovery flows through the same latch', () {
      final ux = ImageDropUx();
      ux.observe(currentDropReport(currentDrops: 5, currentTotal: 25));
      final clear = ux.observe(
        historyDropReport(historyDrops: 0, registry: 20),
      );
      expect(clear, isNotNull);
    });
  });

  group('AC4 — the shared projection', () {
    test('with drops: counts, per-image previews, cap, knobs', () {
      final lines = imageSurfaceLines(
        lastReport: historyDropReport(historyDrops: 2, registry: 22),
        config: const ImageRegistryConfig(),
        modelId: 'test-model',
      );
      final joined = lines.join('\n');
      expect(joined, contains('22 in the window, 20 sent, 2 not sent'));
      expect(joined, contains('dropped [Image 0]'));
      expect(joined, contains('hist-key-'.substring(0, 8)));
      expect(joined, contains('cap: 20 per request for test-model'));
      expect(joined, contains('images.maxPerRequest'));
      expect(joined, contains('images.registry: false'));
    });

    test('before the first report: quiet one-liner, no window claim', () {
      final lines = imageSurfaceLines(
        lastReport: null,
        config: const ImageRegistryConfig(),
        modelId: 'm',
      );
      expect(lines, hasLength(3));
      expect(lines.first, contains('no capped request yet'));
      expect(lines.join(), isNot(contains('in the window')));
      // The knobs stay visible even before any capped request.
      expect(lines.join(), contains('images.registry: false'));
    });

    test('kill switch: the disabled line, nothing else', () {
      final lines = imageSurfaceLines(
        lastReport: null,
        config: const ImageRegistryConfig(enabled: false),
        modelId: 'm',
      );
      expect(lines, hasLength(1));
      expect(lines.single, contains('images.registry: false'));
      expect(lines.single, contains('no drops, no notices'));
    });

    test('a below-every-config cap is labeled as learned (#1750)', () {
      final lines = imageSurfaceLines(
        lastReport: historyDropReport(historyDrops: 1, registry: 11, cap: 10),
        config: const ImageRegistryConfig(),
        modelId: 'test-model',
      );
      expect(lines.join(), contains('learned from a provider refusal'));
    });

    test('a perModel cap is labeled as the override, not learned', () {
      final lines = imageSurfaceLines(
        lastReport: historyDropReport(historyDrops: 1, registry: 11, cap: 8),
        config: const ImageRegistryConfig(perModel: {'test-model': 8}),
        modelId: 'test-model',
      );
      final joined = lines.join('\n');
      expect(joined, contains('images.perModel override'));
      expect(joined, isNot(contains('learned from a provider refusal')));
    });
  });
}
