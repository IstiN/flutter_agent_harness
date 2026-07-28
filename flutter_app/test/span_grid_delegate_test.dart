// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/ui/widgets/span_grid_delegate.dart';
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
}
