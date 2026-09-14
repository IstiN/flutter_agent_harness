/// Mouse hit-regions for the Fa TUI (issue #278).
///
/// Components declare screen rectangles while rendering; clicks route to
/// the topmost region covering the pointer. Pure Dart (no dart_tui types)
/// so both the web stub and unit tests can use it directly.
///
/// Lifecycle: [TuiHitRegionRegistry.clear] runs at the top of every
/// `view()` and the writers re-add their rects — a resize re-derives the
/// rects on the resize frame (E2), and a removed widget simply stops
/// adding (no ghost clicks, AC1).
library;

/// What a registered rect does when clicked.
enum TuiRegionKind {
  /// The transcript viewport: click focuses the composer (the caret stays
  /// where it was); the wheel still scrolls (unchanged behavior, REG).
  scrollback,

  /// The composer input zone: click moves the caret to the clicked cell.
  composer,

  /// One menu/picker row; [TuiHitRegion.index] is the item index — the
  /// click selects and accepts the row like Enter.
  menuRow,

  /// One queued message row; [TuiHitRegion.index] is the queue index —
  /// the click drops the message.
  queueRow,
}

/// One clickable rectangle in screen cells (origin top-left).
final class TuiHitRegion {
  const TuiHitRegion({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.kind,
    this.index = 0,
  });

  final int x;
  final int y;
  final int w;
  final int h;
  final TuiRegionKind kind;

  /// Payload for indexed kinds ([TuiRegionKind.menuRow],
  /// [TuiRegionKind.queueRow]).
  final int index;

  bool contains(int px, int py) =>
      px >= x && px < x + w && py >= y && py < y + h;
}

/// The rect registry of the last rendered frame. Overlap resolves to the
/// LAST region added that contains the point — the frame writers add
/// base-layer rects (scrollback) before overlay rects (menu), so the
/// topmost render wins (AC1).
final class TuiHitRegionRegistry {
  final List<TuiHitRegion> _regions = [];

  /// Drops every region — called once per frame before the writers run,
  /// so unmounted components cannot ghost-click (AC1 teardown).
  void clear() => _regions.clear();

  void add(TuiHitRegion region) => _regions.add(region);

  bool get isEmpty => _regions.isEmpty;
  int get length => _regions.length;

  /// The topmost region at (x, y), or null when the click lands on
  /// unclaimed chrome.
  TuiHitRegion? hitTest(int x, int y) {
    for (final region in _regions.reversed) {
      if (region.contains(x, y)) return region;
    }
    return null;
  }
}

/// A resolved pointer gesture: a click (press → release without dragging)
/// carries the region under the release point; a drag carries nothing —
/// with capture on, a drag is the user attempting a selection, and regions
/// only claim mouse-ups without drag (E1).
sealed class TuiMouseGesture {
  const TuiMouseGesture();
}

final class MouseClickGesture extends TuiMouseGesture {
  const MouseClickGesture(this.region);
  final TuiHitRegion region;
}

/// Press started, moved past the drag threshold, released — no region
/// activation.
final class MouseDragGesture extends TuiMouseGesture {
  const MouseDragGesture();
}

/// Classifies press/motion/release cell coordinates into
/// [MouseClickGesture]/[MouseDragGesture]. State is per-session mutable
/// (held by the TUI model outside `copyWith` — gestures are input
/// plumbing, not model state).
final class TuiMouseRouter {
  /// Drag distance (cells, either axis) past which a press becomes a drag
  /// and the release no longer activates a region (E1).
  static const dragThresholdCells = 3;

  int? _pressX;
  int? _pressY;
  bool _dragging = false;

  bool get isPressed => _pressX != null;

  void pressAt(int x, int y) {
    _pressX = x;
    _pressY = y;
    _dragging = false;
  }

  /// Marks the gesture as a drag once motion passes the threshold.
  void motionTo(int x, int y) {
    if (_pressX == null || _dragging) return;
    final dx = (x - _pressX!).abs();
    final dy = (y - _pressY!).abs();
    if (dx >= dragThresholdCells || dy >= dragThresholdCells) {
      _dragging = true;
    }
  }

  /// Resolves the gesture at release; null when no press was open (a
  /// release without press — e.g. capture toggled mid-gesture — routes
  /// nowhere).
  TuiMouseGesture? releaseAt(int x, int y, TuiHitRegionRegistry regions) {
    final pressed = _pressX != null;
    _pressX = _pressY = null;
    if (!pressed) return null;
    if (_dragging) return const MouseDragGesture();
    final region = regions.hitTest(x, y);
    if (region == null) return null;
    return MouseClickGesture(region);
  }
}
