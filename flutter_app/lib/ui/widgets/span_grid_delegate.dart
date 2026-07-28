// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/rendering.dart';

/// A tile span in grid cells (width × height).
typedef TileSpan = ({int w, int h});

/// Where one tile lands in the grid (0-based row/column of its top-left
/// cell).
typedef TilePlacement = ({int row, int col});

/// iOS-home-screen grid geometry: the grid unit is the APP-ICON SLOT — one
/// icon square ([iconSize]) plus its label strip ([labelHeight]) below.
/// A WxH live tile measures exactly the outer edges of the WxH block of
/// icon slots it replaces, so widget edges always align with icon edges.
abstract final class LauncherGridSpec {
  /// App-icon square side, in logical pixels.
  static const double iconSize = 56;

  /// Height of the label strip under the icon square.
  static const double labelHeight = 20;

  /// Gap between cells, both axes.
  static const double spacing = 16;

  /// Cross-axis extent of one cell (the icon square).
  static const double cellCrossExtent = iconSize;

  /// Main-axis extent of one cell (icon square + label strip).
  static const double cellMainExtent = iconSize + labelHeight;

  /// Cross-axis extent of a [cells]-wide span (including inner gaps).
  static double spanCrossExtent(int cells) =>
      cells * cellCrossExtent + (cells - 1) * spacing;

  /// Main-axis extent of a [cells]-high span (including inner gaps).
  static double spanMainExtent(int cells) =>
      cells * cellMainExtent + (cells - 1) * spacing;

  /// Cross-axis extent of the whole grid at [columns] columns.
  static double gridCrossExtent(int columns) => spanCrossExtent(columns);
}

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

/// The pixel rect (top-left + extent) of one placed tile.
typedef TileRect = ({double x, double y, double w, double h});

/// Lays [spans] out with [packTileSpans] and converts placements to pixel
/// rects on the [LauncherGridSpec] geometry: x/y are the top-left of the
/// tile's slot block, w/h the exact WxH block extent.
List<TileRect> layOutTileRects({
  required int crossAxisCount,
  required List<TileSpan> spans,
}) {
  final placements = packTileSpans(
    crossAxisCount: crossAxisCount,
    spans: spans,
  );
  return [
    for (var i = 0; i < spans.length; i++)
      (
        x:
            placements[i].col *
            (LauncherGridSpec.cellCrossExtent + LauncherGridSpec.spacing),
        y:
            placements[i].row *
            (LauncherGridSpec.cellMainExtent + LauncherGridSpec.spacing),
        w: LauncherGridSpec.spanCrossExtent(
          spans[i].w.clamp(1, crossAxisCount),
        ),
        h: LauncherGridSpec.spanMainExtent(spans[i].h < 1 ? 1 : spans[i].h),
      ),
  ];
}

/// The total main-axis extent needed to show every rect of [layOutTileRects]
/// (0 for an empty grid).
double packedTilesHeight(List<TileRect> rects) {
  var max = 0.0;
  for (final rect in rects) {
    final bottom = rect.y + rect.h;
    if (bottom > max) max = bottom;
  }
  return max;
}

/// Rectangular-cell grid delegate with per-child spans (see [packTileSpans])
/// on the [LauncherGridSpec] icon-unit geometry. A WxH tile measures
/// `W` × `H` cells plus the inter-cell spacing inside the span.
class SpanGridDelegate extends SliverGridDelegate {
  SpanGridDelegate({
    required this.crossAxisCount,
    required this.spans,
    this.crossAxisCellExtent = LauncherGridSpec.cellCrossExtent,
    this.mainAxisCellExtent = LauncherGridSpec.cellMainExtent,
    this.spacing = LauncherGridSpec.spacing,
  });

  /// Fixed column count (derived from the available width by the caller).
  final int crossAxisCount;

  /// Per-child spans, indexed like the grid's children.
  final List<TileSpan> spans;

  /// Cross-axis extent of one cell (the icon square on the launcher).
  final double crossAxisCellExtent;

  /// Main-axis extent of one cell (icon square + label strip).
  final double mainAxisCellExtent;

  /// Gap between cells (applied inside spans too).
  final double spacing;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final placements = packTileSpans(
      crossAxisCount: crossAxisCount,
      spans: spans,
    );
    return _SpanGridLayout([
      for (var i = 0; i < spans.length; i++)
        (
          x: placements[i].col * (crossAxisCellExtent + spacing),
          y: placements[i].row * (mainAxisCellExtent + spacing),
          w: _spanExtent(
            spans[i].w.clamp(1, crossAxisCount),
            crossAxisCellExtent,
          ),
          h: _spanExtent(spans[i].h < 1 ? 1 : spans[i].h, mainAxisCellExtent),
        ),
    ]);
  }

  double _spanExtent(int cells, double cell) =>
      cells * cell + (cells - 1) * spacing;

  @override
  bool shouldRelayout(SpanGridDelegate oldDelegate) {
    if (crossAxisCount != oldDelegate.crossAxisCount ||
        crossAxisCellExtent != oldDelegate.crossAxisCellExtent ||
        mainAxisCellExtent != oldDelegate.mainAxisCellExtent ||
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
  final List<TileRect> _tiles;

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
  double computeMaxScrollOffset(int childCount) => packedTilesHeight(_tiles);
}
