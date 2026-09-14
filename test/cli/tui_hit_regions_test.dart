// Unit tests for the mouse hit-region registry and router (issue #278,
// AC1): overlap → topmost wins, click/drag classification, teardown.
import 'package:flutter_agent_harness/src/cli/tui_hit_regions.dart';
import 'package:test/test.dart';

void main() {
  TuiHitRegion region({
    int x = 0,
    int y = 0,
    int w = 10,
    int h = 1,
    TuiRegionKind kind = TuiRegionKind.composer,
    int index = 0,
  }) => TuiHitRegion(x: x, y: y, w: w, h: h, kind: kind, index: index);

  group('TuiHitRegionRegistry', () {
    test('overlap resolves to the LAST added region (topmost wins)', () {
      final registry = TuiHitRegionRegistry();
      final base = region(kind: TuiRegionKind.scrollback);
      final overlay = region(kind: TuiRegionKind.menuRow, index: 2);
      registry
        ..add(base)
        ..add(overlay);
      expect(registry.hitTest(3, 0), same(overlay));
    });

    test('hitTest returns null on unclaimed chrome', () {
      final registry = TuiHitRegionRegistry()..add(region(x: 0, y: 0, w: 5));
      expect(registry.hitTest(6, 0), isNull);
      expect(registry.hitTest(0, 1), isNull);
      expect(registry.hitTest(-1, 0), isNull);
    });

    test('contains() bounds are half-open (w/h excluded)', () {
      final r = region(x: 2, y: 3, w: 4, h: 2);
      expect(r.contains(5, 4), isTrue);
      expect(r.contains(6, 4), isFalse);
      expect(r.contains(2, 5), isFalse);
    });

    test('clear() drops every region — unmounted widgets cannot ghost-click',
        () {
      final registry = TuiHitRegionRegistry()..add(region());
      expect(registry.isEmpty, isFalse);
      registry.clear();
      expect(registry.isEmpty, isTrue);
      expect(registry.hitTest(0, 0), isNull);
    });
  });

  group('TuiMouseRouter', () {
    test('press + release inside a region classifies a click', () {
      final registry = TuiHitRegionRegistry()
        ..add(region(kind: TuiRegionKind.queueRow, index: 1));
      final router = TuiMouseRouter();
      router.pressAt(3, 0);
      final gesture = router.releaseAt(4, 0, registry);
      expect(gesture, isA<MouseClickGesture>());
      expect(
        (gesture as MouseClickGesture).region.kind,
        TuiRegionKind.queueRow,
      );
    });

    test('the click carries the region under the RELEASE point', () {
      final registry = TuiHitRegionRegistry()
        ..add(region(kind: TuiRegionKind.scrollback))
        ..add(region(kind: TuiRegionKind.composer));
      final router = TuiMouseRouter();
      router.pressAt(1, 0);
      final gesture = router.releaseAt(2, 0, registry) as MouseClickGesture;
      expect(gesture.region.kind, TuiRegionKind.composer);
    });

    test('release outside every region routes nothing (unclaimed chrome)',
        () {
      final registry = TuiHitRegionRegistry()..add(region(w: 2));
      final router = TuiMouseRouter();
      router.pressAt(1, 0);
      expect(router.releaseAt(9, 9, registry), isNull);
    });

    test('motion past the threshold turns the release into a drag (E1)', () {
      final registry = TuiHitRegionRegistry()..add(region());
      final router = TuiMouseRouter();
      router.pressAt(0, 0);
      router.motionTo(TuiMouseRouter.dragThresholdCells, 0);
      expect(router.releaseAt(0, 0, registry), isA<MouseDragGesture>());
    });

    test('motion within the threshold keeps the click', () {
      final registry = TuiHitRegionRegistry()..add(region());
      final router = TuiMouseRouter();
      router.pressAt(0, 0);
      router.motionTo(TuiMouseRouter.dragThresholdCells - 1, 0);
      expect(router.releaseAt(0, 0, registry), isA<MouseClickGesture>());
    });

    test('release without a press routes nowhere', () {
      final registry = TuiHitRegionRegistry()..add(region());
      final router = TuiMouseRouter();
      expect(router.releaseAt(0, 0, registry), isNull);
      expect(router.isPressed, isFalse);
    });

    test('a new press resets the drag state', () {
      final registry = TuiHitRegionRegistry()..add(region());
      final router = TuiMouseRouter();
      router.pressAt(0, 0);
      router.motionTo(9, 0);
      router.releaseAt(9, 0, registry);
      router.pressAt(0, 0);
      expect(router.releaseAt(0, 0, registry), isA<MouseClickGesture>());
    });
  });
}
