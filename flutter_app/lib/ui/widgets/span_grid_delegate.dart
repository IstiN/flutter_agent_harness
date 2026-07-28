// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/rendering.dart';

/// A tile span in grid cells (width × height).
typedef TileSpan = ({int w, int h});

/// Where one tile lands in the grid (0-based row/column of its top-left
/// cell).
typedef TilePlacement = ({int row, int col});

/// Greedy first-fit row packing of [spans] into a grid with
/// [crossAxisCount] columns: each tile takes the first top-left position
/// (scanning rows top-to-bottom, columns left-to-right) whose WxH block is
/// free, possibly leaving holes — iOS-home-screen-like, no reflow. Spans
/// are clamped to the grid (width 1..[crossAxisCount], height at least 1).
/// Child index ↔ span index stays 1:1, so reorder logic is unaffected.
List<TilePlacement> packTileSpans({
  required int crossAxisCount,
  required List<TileSpan> spans,
}) {
  // rows[r][c] = occupied; rows are appended on demand.
  final rows = <List<bool>>[];
  final placements = <TilePlacement>[];
  for (final span in spans) {
    final w = span.w.clamp(1, crossAxisCount);
    final h = span.h < 1 ? 1 : span.h;
    var placed = false;
    for (var row = 0; !placed; row++) {
      while (rows.length < row + h) {
        rows.add(List<bool>.filled(crossAxisCount, false));
      }
      for (var col = 0; col + w <= crossAxisCount && !placed; col++) {
        var fits = true;
        for (var dr = 0; dr < h && fits; dr++) {
          for (var dc = 0; dc < w && fits; dc++) {
            if (rows[row + dr][col + dc]) fits = false;
          }
        }
        if (fits) {
          for (var dr = 0; dr < h; dr++) {
            for (var dc = 0; dc < w; dc++) {
              rows[row + dr][col + dc] = true;
            }
          }
          placements.add((row: row, col: col));
          placed = true;
        }
      }
    }
  }
  return placements;
}

/// Square-cell grid delegate with per-child spans (see [packTileSpans]):
/// the launcher home grid where apps declaring a live tile
/// (`JsTileWidgetInfo`) can occupy more than one cell. A WxH tile measures
/// `W` cells × `H` cells plus the inter-cell [spacing] inside the span.
class SpanGridDelegate extends SliverGridDelegate {
  SpanGridDelegate({
    required this.crossAxisCount,
    required this.spans,
    this.spacing = 0,
  });

  /// Fixed column count (derived from the available width by the caller,
  /// matching `SliverGridDelegateWithMaxCrossAxisExtent`'s behavior).
  final int crossAxisCount;

  /// Per-child spans, indexed like the grid's children.
  final List<TileSpan> spans;

  /// Gap between cells (applied inside spans too).
  final double spacing;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final cell =
        (constraints.crossAxisExtent - spacing * (crossAxisCount - 1)) /
        crossAxisCount;
    final placements = packTileSpans(
      crossAxisCount: crossAxisCount,
      spans: spans,
    );
    return _SpanGridLayout([
      for (var i = 0; i < spans.length; i++)
        (
          x: placements[i].col * (cell + spacing),
          y: placements[i].row * (cell + spacing),
          w: _spanExtent(spans[i].w.clamp(1, crossAxisCount), cell),
          h: _spanExtent(spans[i].h < 1 ? 1 : spans[i].h, cell),
        ),
    ]);
  }

  double _spanExtent(int cells, double cell) =>
      cells * cell + (cells - 1) * spacing;

  @override
  bool shouldRelayout(SpanGridDelegate oldDelegate) {
    if (crossAxisCount != oldDelegate.crossAxisCount ||
        spacing != oldDelegate.spacing ||
        spans.length != oldDelegate.spans.length) {
      return true;
    }
    for (var i = 0; i < spans.length; i++) {
      if (spans[i] != oldDelegate.spans[i]) return true;
    }
    return false;
  }
}

class _SpanGridLayout extends SliverGridLayout {
  _SpanGridLayout(this._tiles);

  /// Per-child geometry: top-left offset + extent, in pixels. Note y is NOT
  /// monotonic in index (first-fit backfills holes), so the scroll-offset
  /// queries scan linearly — the grid is a screenful of tiles, not a list.
  final List<({double x, double y, double w, double h})> _tiles;

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    for (var i = 0; i < _tiles.length; i++) {
      if (_tiles[i].y + _tiles[i].h > scrollOffset) return i;
    }
    return _tiles.isEmpty ? 0 : _tiles.length - 1;
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    for (var i = _tiles.length - 1; i >= 0; i--) {
      if (_tiles[i].y < scrollOffset) return i;
    }
    return 0;
  }

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    final tile = _tiles[index];
    return SliverGridGeometry(
      scrollOffset: tile.y,
      crossAxisOffset: tile.x,
      mainAxisExtent: tile.h,
      crossAxisExtent: tile.w,
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) {
    var max = 0.0;
    for (final tile in _tiles) {
      final bottom = tile.y + tile.h;
      if (bottom > max) max = bottom;
    }
    return max;
  }
}
