// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/ui/widgets/span_grid_delegate.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('packTileSpans', () {
    test('uniform 1x1 tiles fill row-major', () {
      final placements = packTileSpans(
        crossAxisCount: 3,
        spans: const [(w: 1, h: 1), (w: 1, h: 1), (w: 1, h: 1), (w: 1, h: 1)],
      );
      expect(placements, [
        (row: 0, col: 0),
        (row: 0, col: 1),
        (row: 0, col: 2),
        (row: 1, col: 0),
      ]);
    });

    test('a 2x1 tile occupies two columns of one row', () {
      final placements = packTileSpans(
        crossAxisCount: 3,
        spans: const [(w: 2, h: 1), (w: 1, h: 1), (w: 1, h: 1)],
      );
      expect(placements, [
        (row: 0, col: 0),
        (row: 0, col: 2), // only one cell left in row 0
        (row: 1, col: 0),
      ]);
    });

    test('first-fit leaves holes, later small tiles backfill them', () {
      final placements = packTileSpans(
        crossAxisCount: 3,
        spans: const [(w: 2, h: 1), (w: 2, h: 1), (w: 1, h: 1)],
      );
      expect(placements, [
        (row: 0, col: 0), // cells (0,0)-(0,1)
        (row: 1, col: 0), // (0,2) alone can't fit 2 wide → next row
        (row: 0, col: 2), // the 1x1 backfills the hole
      ]);
    });

    test('a 2x2 tile reserves its block across two rows', () {
      final placements = packTileSpans(
        crossAxisCount: 3,
        spans: const [(w: 2, h: 2), (w: 1, h: 1), (w: 1, h: 1), (w: 2, h: 1)],
      );
      expect(placements, [
        (row: 0, col: 0), // block rows 0-1, cols 0-1
        (row: 0, col: 2),
        (row: 1, col: 2),
        (row: 2, col: 0), // row 0/1 have no 2-wide gap left
      ]);
    });

    test('spans wider than the grid clamp to the column count', () {
      final placements = packTileSpans(
        crossAxisCount: 2,
        spans: const [(w: 3, h: 1), (w: 1, h: 1)],
      );
      expect(placements, [
        (row: 0, col: 0), // clamped to 2 wide → fills the whole row
        (row: 1, col: 0),
      ]);
    });

    test('empty span list packs to nothing', () {
      expect(packTileSpans(crossAxisCount: 3, spans: const []), isEmpty);
    });
  });

  group('layOutTileRects (icon-unit geometry)', () {
    test('a 1x1 slot is exactly the icon square + label strip', () {
      final rects = layOutTileRects(
        crossAxisCount: 4,
        spans: const [(w: 1, h: 1)],
      );
      expect(rects.single.x, 0);
      expect(rects.single.y, 0);
      expect(rects.single.w, LauncherGridSpec.iconSize);
      expect(
        rects.single.h,
        LauncherGridSpec.iconSize + LauncherGridSpec.labelHeight,
      );
    });

    test('a WxH tile aligns with the outer edges of its icon-slot block', () {
      // 4 columns: a 4x2 tile fills the first two rows entirely.
      final rects = layOutTileRects(
        crossAxisCount: 4,
        spans: const [(w: 4, h: 2), (w: 2, h: 2), (w: 1, h: 1)],
      );
      const i = LauncherGridSpec.iconSize;
      const g = LauncherGridSpec.spacing;
      const cellMain = LauncherGridSpec.cellMainExtent;
      // 4x2 at the origin: width of 4 slots + 3 gaps, height of 2 + 1 gap.
      expect(rects[0], (x: 0.0, y: 0.0, w: 4 * i + 3 * g, h: 2 * cellMain + g));
      // 2x2 packs into row 2; its left edge == column 0's icon left edge.
      expect(rects[1].x, 0.0);
      expect(rects[1].y, 2 * (cellMain + g));
      expect(rects[1].w, 2 * i + g);
      expect(rects[1].h, 2 * cellMain + g);
      // The 1x1 app tile after it starts exactly at column 2's left edge.
      expect(rects[2].x, 2 * (i + g));
      expect(rects[2].y, 2 * (cellMain + g));
      expect(rects[2].w, i);
      expect(rects[2].h, cellMain);
      // Total height covers two 2-high rows.
      expect(packedTilesHeight(rects), 4 * cellMain + 3 * g);
    });
  });

  group('SpanGridDelegate (rectangular cells)', () {
    test('geometry: WxH span = W x H cells + inner spacing', () {
      final delegate = SpanGridDelegate(
        crossAxisCount: 4,
        spans: const [(w: 2, h: 2), (w: 1, h: 1)],
      );
      final layout = delegate.getLayout(
        const SliverConstraints(
          axisDirection: AxisDirection.down,
          growthDirection: GrowthDirection.forward,
          userScrollDirection: ScrollDirection.idle,
          scrollOffset: 0,
          precedingScrollExtent: 0,
          overlap: 0,
          remainingPaintExtent: 800,
          crossAxisExtent: 4 * 56 + 3 * 16,
          crossAxisDirection: AxisDirection.right,
          viewportMainAxisExtent: 800,
          remainingCacheExtent: 800,
          cacheOrigin: 0,
        ),
      );
      const cellMain = LauncherGridSpec.cellMainExtent;
      const g = LauncherGridSpec.spacing;
      final first = layout.getGeometryForChildIndex(0);
      expect(first.scrollOffset, 0);
      expect(first.crossAxisOffset, 0);
      expect(first.crossAxisExtent, 2 * 56 + g);
      expect(first.mainAxisExtent, 2 * cellMain + g);
      final second = layout.getGeometryForChildIndex(1);
      expect(second.crossAxisOffset, 2 * (56 + g));
      expect(second.mainAxisExtent, cellMain);
      expect(layout.computeMaxScrollOffset(2), 2 * cellMain + g);
    });

    test('shouldRelayout reacts to spans and extents', () {
      final a = SpanGridDelegate(
        crossAxisCount: 4,
        spans: const [(w: 2, h: 2)],
      );
      expect(
        a.shouldRelayout(
          SpanGridDelegate(crossAxisCount: 4, spans: const [(w: 2, h: 2)]),
        ),
        isFalse,
      );
      expect(
        a.shouldRelayout(
          SpanGridDelegate(crossAxisCount: 3, spans: const [(w: 2, h: 2)]),
        ),
        isTrue,
      );
      expect(
        a.shouldRelayout(
          SpanGridDelegate(crossAxisCount: 4, spans: const [(w: 4, h: 2)]),
        ),
        isTrue,
      );
    });
  });
}
