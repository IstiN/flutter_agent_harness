// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:math';

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

    test('a tile that does not fit wraps; trailing cells stay blank', () {
      final placements = packTileSpans(
        crossAxisCount: 3,
        spans: const [(w: 2, h: 1), (w: 2, h: 1), (w: 1, h: 1)],
      );
      expect(placements, [
        (row: 0, col: 0), // cells (0,0)-(0,1)
        (row: 1, col: 0), // (0,2) alone can't fit 2 wide → next row
        (row: 1, col: 2), // stays after the wrap — (0,2) is left blank
      ]);
    });

    test('later tiles never backfill an earlier row (order preserved)', () {
      // 4 columns: the 4x2 tile wraps past the leading 1x1, so the row-0
      // trailing cells are blank and everything after the wrap packs at or
      // below the wide tile — reading order == tile order.
      final placements = packTileSpans(
        crossAxisCount: 4,
        spans: const [(w: 1, h: 1), (w: 4, h: 2), (w: 1, h: 1)],
      );
      expect(placements, [
        (row: 0, col: 0),
        (row: 1, col: 0), // wraps: row 0 has only 3 cells left
        (row: 3, col: 0), // below the 2-high tile, NOT back in row 0
      ]);
    });

    // AC3 of issue #166: for ANY span sequence, tiles never overlap, the
    // packing stays within the grid, and reading order is preserved.
    test('property: any span sequence packs in order without overlap', () {
      final random = Random(42);
      for (var trial = 0; trial < 300; trial++) {
        final columns = 2 + random.nextInt(7); // 2..8
        final count = random.nextInt(12);
        final spans = [
          for (var i = 0; i < count; i++)
            (w: 1 + random.nextInt(6), h: 1 + random.nextInt(4)),
        ];
        final placements = packTileSpans(
          crossAxisCount: columns,
          spans: spans,
        );
        expect(placements.length, spans.length, reason: 'trial $trial');
        final occupied = <String>{};
        var lastRow = 0;
        var lastCol = -1;
        for (var i = 0; i < spans.length; i++) {
          final w = spans[i].w.clamp(1, columns);
          final h = spans[i].h < 1 ? 1 : spans[i].h;
          final p = placements[i];
          // Within the grid bounds (a span wider than the grid clamps to
          // full width — AC4).
          expect(p.col + w, lessThanOrEqualTo(columns),
              reason: 'trial $trial tile $i overflows the row');
          expect(p.col, greaterThanOrEqualTo(0));
          expect(p.row, greaterThanOrEqualTo(0));
          // No overlap.
          for (var r = 0; r < h; r++) {
            for (var c = 0; c < w; c++) {
              expect(occupied.add('${p.row + r}:${p.col + c}'), isTrue,
                  reason: 'trial $trial tile $i overlaps at '
                      '(${p.row + r},${p.col + c})');
            }
          }
          // Order preserved: row-major reading order never goes backwards.
          expect(p.row, greaterThanOrEqualTo(lastRow),
              reason: 'trial $trial tile $i broke reading order');
          if (p.row == lastRow) {
            expect(p.col, greaterThan(lastCol),
                reason: 'trial $trial tile $i broke reading order');
          }
          lastRow = p.row;
          lastCol = p.col;
        }
        // Deterministic.
        expect(
          packTileSpans(crossAxisCount: columns, spans: spans),
          placements,
          reason: 'trial $trial is not deterministic',
        );
      }
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
  group('launcherGridHoverTarget', () {
    // Two rows; Beta is a 2x2 tall tile, so row 0's bottom edge is its
    // own (y=0 + h=112), not Alpha's (y=0 + h=56).
    final keys = ['a', 'b', 'c'];
    final rects = [
      (x: 0.0, y: 0.0, w: 56.0, h: 56.0), // a (row 0)
      (x: 72.0, y: 0.0, w: 112.0, h: 112.0), // b (row 0, tall)
      (x: 0.0, y: 128.0, w: 56.0, h: 56.0), // c (row 1)
    ];

    test('above the first row targets the first tile before it', () {
      expect(
        launcherGridHoverTarget(
          pointer: const Offset(30, -10),
          keys: keys,
          rects: rects,
        ),
        ('a', 0.0),
      );
    });

    test('inside a row: the first center right of the pointer wins', () {
      // Alpha's center is at x=28.
      expect(
        launcherGridHoverTarget(
          pointer: const Offset(10, 10),
          keys: keys,
          rects: rects,
        ),
        ('a', 0.0),
      );
      // Between Alpha's and Beta's centers → inserts before Beta.
      expect(
        launcherGridHoverTarget(
          pointer: const Offset(40, 10),
          keys: keys,
          rects: rects,
        ),
        ('b', 0.0),
      );
      // Beta's center is at x=128.
      expect(
        launcherGridHoverTarget(
          pointer: const Offset(100, 10),
          keys: keys,
          rects: rects,
        ),
        ('b', 0.0),
      );
      expect(
        launcherGridHoverTarget(
          pointer: const Offset(150, 10),
          keys: keys,
          rects: rects,
        ),
        ('b', 1.0),
      );
    });

    test('row extent follows the tallest tile, not the first', () {
      // y=60 is past Alpha's bottom (56) but inside Beta's (112): still
      // row 0.
      expect(
        launcherGridHoverTarget(
          pointer: const Offset(10, 60),
          keys: keys,
          rects: rects,
        ),
        ('a', 0.0),
      );
    });

    test('later rows group by y, not index order', () {
      // c starts at y=128: a pointer there scans row 1 only.
      expect(
        launcherGridHoverTarget(
          pointer: const Offset(10, 140),
          keys: keys,
          rects: rects,
        ),
        ('c', 0.0),
      );
    });

    test('below every row targets the last tile after it', () {
      expect(
        launcherGridHoverTarget(
          pointer: const Offset(30, 500),
          keys: keys,
          rects: rects,
        ),
        ('c', 1.0),
      );
    });

    test('rows group by y even when stored out of order (backfill)', () {
      // Same grid, but the parallel lists store row 1 first (hole
      // backfill order): grouping must still key on y.
      const backfillKeys = ['c', 'a', 'b'];
      final backfillRects = [rects[2], rects[0], rects[1]];
      expect(
        launcherGridHoverTarget(
          pointer: const Offset(10, 140),
          keys: backfillKeys,
          rects: backfillRects,
        ),
        ('c', 0.0),
      );
      expect(
        launcherGridHoverTarget(
          pointer: const Offset(10, -5),
          keys: backfillKeys,
          rects: backfillRects,
        ),
        ('c', 0.0),
      );
      expect(
        launcherGridHoverTarget(
          pointer: const Offset(10, 10),
          keys: backfillKeys,
          rects: backfillRects,
        ),
        ('a', 0.0),
      );
    });
  });
}
