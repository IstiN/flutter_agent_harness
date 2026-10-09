// The shared follow-mode contract (gh-1439): a transcript viewport is
// either `live` (auto-follow the stream) or `held` (user scrolled up; the
// viewport stays anchored while output keeps arriving, counted). ONE pure
// state machine owns the contract for every surface — the CLI TUI, the
// Flutter app, and the web harness all classify scrolls and count unseen
// through this file (AC3: assert the shared owner, never a copy).
library;

import 'package:flutter_agent_harness/src/viewport/follow_mode.dart';
import 'package:test/test.dart';

void main() {
  group('boot/resume (AC5)', () {
    test('a fresh viewport always starts live with zero unseen', () {
      const mode = FollowMode.live();
      expect(mode.isLive, isTrue);
      expect(mode.isHeld, isFalse);
      expect(mode.unseen, 0);
    });

    test('held state is never persisted: a new instance never inherits', () {
      const held = FollowMode.held(unseen: 42);
      // A restarted viewport constructs a fresh FollowMode — the old
      // instance's state cannot leak (AC5).
      expect(FollowMode.live().isHeld, isFalse);
      expect(FollowMode.live().unseen, 0);
      expect(held.isHeld, isTrue, reason: 'the old instance is unchanged');
    });
  });

  group('user scroll classification', () {
    test('any user scroll away from the live edge disengages (held)', () {
      const live = FollowMode.live();
      final held = live.userScrolled(
        distanceFromLiveEdge: 5,
        armExtent: 2,
        movedTowardLive: false,
      );
      expect(held.isHeld, isTrue);
      expect(held.unseen, 0, reason: 'nothing has arrived yet');
    });

    test('a one-unit scroll away disengages — the arm band never swallows '
        'the disengage trigger', () {
      const live = FollowMode.live();
      expect(
        live.userScrolled(
          distanceFromLiveEdge: 1,
          armExtent: 2,
          movedTowardLive: false,
        ).isHeld,
        isTrue,
      );
    });

    test('scrolling back toward the live edge within the arm band '
        're-engages and flushes unseen', () {
      const held = FollowMode.held(unseen: 30);
      final rearmed = held.userScrolled(
        distanceFromLiveEdge: 2,
        armExtent: 2,
        movedTowardLive: true,
      );
      expect(rearmed.isLive, isTrue);
      expect(rearmed.unseen, 0, reason: 're-engage flushes the count');
    });

    test('scrolling toward the live edge but stopping outside the band '
        'stays held and keeps counting', () {
      const held = FollowMode.held(unseen: 30);
      final still = held.userScrolled(
        distanceFromLiveEdge: 3,
        armExtent: 2,
        movedTowardLive: true,
      );
      expect(still.isHeld, isTrue);
      expect(still.unseen, 30, reason: 'unseen is preserved while held');
    });

    test('landing exactly on the live edge always re-engages (arm 0)', () {
      const held = FollowMode.held(unseen: 7);
      expect(
        held.userScrolled(
          distanceFromLiveEdge: 0,
          armExtent: 0,
          movedTowardLive: true,
        ).isLive,
        isTrue,
      );
    });

    test('a zero distance is live regardless of direction', () {
      const live = FollowMode.live();
      expect(
        live
            .userScrolled(
              distanceFromLiveEdge: 0,
              armExtent: 2,
              movedTowardLive: false,
            )
            .isLive,
        isTrue,
        reason: 'the live edge itself can never hold',
      );
    });

    test('further scrolls away while held keep the unseen count', () {
      const held = FollowMode.held(unseen: 12);
      expect(
        held
            .userScrolled(
              distanceFromLiveEdge: 40,
              armExtent: 2,
              movedTowardLive: false,
            )
            .unseen,
        12,
      );
    });
  });

  group('unseen counting (zero loss — AC4)', () {
    test('live appends are never counted (the viewport shows them)', () {
      const live = FollowMode.live();
      expect(live.appended(1).unseen, 0);
      expect(live.appended(50).unseen, 0);
      expect(live.appended(1).isLive, isTrue);
    });

    test('held appends accumulate — every event is counted, none shown '
        'by force', () {
      var held = const FollowMode.held();
      for (var i = 0; i < 50; i++) {
        held = held.appended(1);
      }
      expect(held.isHeld, isTrue);
      expect(held.unseen, 50);
    });

    test('multi-unit appends (a settle card block) count as one delta', () {
      const held = FollowMode.held(unseen: 3);
      expect(held.appended(12).unseen, 15);
    });

    test('a negative delta never drives the count negative', () {
      const held = FollowMode.held(unseen: 2);
      expect(held.appended(-5).unseen, 2, reason: 'counts never shrink');
    });

    test('jump-to-live flushes the count in one action', () {
      const held = FollowMode.held(unseen: 99);
      final live = held.jumpToLive();
      expect(live.isLive, isTrue);
      expect(live.unseen, 0);
    });
  });

  group('near-bottom arm band (shared fraction, open question 1)', () {
    test('the arm extent is ~10% of the viewport extent', () {
      expect(FollowMode.nearBottomArmExtent(1000), 100);
      expect(FollowMode.nearBottomArmExtent(24), 2);
      expect(FollowMode.nearBottomArmExtent(19), 2);
    });

    test('the extent floors at one unit so tiny viewports still re-arm', () {
      expect(FollowMode.nearBottomArmExtent(3), 1);
      expect(FollowMode.nearBottomArmExtent(1), 1);
    });

    test('a zero/negative extent yields zero (no band, no crash)', () {
      expect(FollowMode.nearBottomArmExtent(0), 0);
      expect(FollowMode.nearBottomArmExtent(-5), 0);
    });
  });

  group('value semantics', () {
    test('equal states compare equal (app setState relies on it)', () {
      expect(const FollowMode.held(unseen: 4), const FollowMode.held(unseen: 4));
      expect(const FollowMode.live(), const FollowMode.live());
      expect(const FollowMode.held(unseen: 4), isNot(const FollowMode.held(unseen: 5)));
      expect(const FollowMode.live(), isNot(const FollowMode.held(unseen: 0)));
      expect(const FollowMode.held(unseen: 4).hashCode, const FollowMode.held(unseen: 4).hashCode);
    });
  });
}
