// The follow-mode contract (gh-1439): while the agent is producing
// output, a user who scrolls up to read history STAYS there, and a
// one-action «jump to live» affordance brings them back when they choose.
//
// ONE pure state machine owns the contract for every surface — the CLI
// TUI, the Flutter app and the web harness share it (AC3: assert the
// shared owner, never a per-surface copy). Surfaces keep their own
// presentation (TUI fold-line counter, app jump pill) and their own
// scroll units (TUI: key/wheel events, app: messages), but the
// disengage/re-engage classification, the unseen counting and the flush
// all flow through [FollowMode].
//
// Invariants (gh-1439):
// - Zero output loss: held mode appends everything to the transcript
//   model; only the VIEWPORT withholds. `unseen` counts what arrived.
// - Re-engage is exactly one action and the affordance is visible
//   whenever `unseen > 0`.
// - Near-bottom re-arm: a user scroll that lands within
//   [nearBottomArmExtent] of the live edge re-engages automatically —
//   but a re-arm fires only for a USER gesture; programmatic viewport
//   moves never classify (E6 debounce).
// - Boot/resume always starts `live` at the newest record; held state
//   never persists across restarts (AC5) — a fresh [FollowMode.live()]
//   is the only starting point.
library;

import 'dart:math' as math;

/// The per-viewport follow state (gh-1439): `live` (auto-follow on) ⇄
/// `held` (user scrolled up; output appended to the model, viewport
/// anchored) with a counted [unseen] delta while held.
///
/// Immutable: every transition returns a new instance. Value equality so
/// reactive hosts (Flutter `setState` gates) can compare cheaply.
final class FollowMode {
  /// The boot/resume state: auto-follow at the newest record (AC5).
  const FollowMode.live() : isHeld = false, unseen = 0;

  /// The held state: the user scrolled up; [unseen] output units have
  /// arrived since.
  const FollowMode.held({this.unseen = 0})
    : assert(unseen >= 0, 'unseen counts never go negative'),
      isHeld = true;

  /// Whether the user scrolled away from the live edge (auto-follow off).
  final bool isHeld;

  /// Whether the viewport auto-follows the stream.
  bool get isLive => !isHeld;

  /// Output units that arrived while held (viewport withheld them;
  /// the model kept everything — zero loss, AC4). Never negative.
  final int unseen;

  /// Near-bottom re-arm band as a fraction of the viewport extent
  /// (gh-1439 open question 1: shared fraction, leaning ~10%). One band
  /// for every surface so the catch-up gesture feels the same everywhere.
  static const double nearBottomArmFraction = 0.10;

  /// The near-bottom re-arm band for a [viewportExtent] (px in the app,
  /// rows in the TUI): ~10% of the extent, floored at one unit so tiny
  /// viewports still re-arm. A zero/negative extent yields zero — no
  /// band, exact-edge re-arm only, never a crash.
  static int nearBottomArmExtent(int viewportExtent) {
    if (viewportExtent <= 0) return 0;
    return math.max(1, (viewportExtent * nearBottomArmFraction).round());
  }

  /// Classifies a USER scroll landing [distanceFromLiveEdge] units from
  /// the live edge, with [armExtent] the near-bottom re-arm band (0 =
  /// exact-edge re-arm only). Position-governed — the standard chat
  /// heuristic:
  ///
  /// - Landing within the band (or on the edge): live again, flushed —
  ///   the common «scroll down to catch up» case needs no button press,
  ///   and a small park near the bottom never yanks the user.
  /// - Landing beyond the band: held, unseen preserved — the user is
  ///   reading; the stream must not move the window.
  ///
  /// E6 debounce: only user gestures classify. The stream/programmatic
  /// viewport moves never call this (the app's own clamps included —
  /// issue #379's follow clamp must keep working), so a re-arm or a hold
  /// can only ever be produced by the user's own position.
  FollowMode userScrolled({
    required int distanceFromLiveEdge,
    required int armExtent,
  }) {
    if (distanceFromLiveEdge <= armExtent) return const FollowMode.live();
    return heldPreservingUnseen();
  }

  /// Output appended while the viewport stands in this state: counted
  /// when held (the affordance's live counter), invisible when live (the
  /// viewport shows it — today's behavior, REG-pinned).
  FollowMode appended(int count) {
    if (isLive) return this;
    if (count <= 0) return this;
    return FollowMode.held(unseen: unseen + count);
  }

  /// The explicit re-engage (End key / jump chip / pill tap / wheel to
  /// the bottom): exactly one action, live again, count flushed.
  FollowMode jumpToLive() => const FollowMode.live();

  FollowMode heldPreservingUnseen() =>
      isHeld ? this : FollowMode.held(unseen: unseen);

  @override
  bool operator ==(Object other) =>
      other is FollowMode &&
      other.isHeld == isHeld &&
      other.unseen == unseen;

  @override
  int get hashCode => Object.hash(isHeld, unseen);

  @override
  String toString() =>
      isLive ? 'FollowMode.live()' : 'FollowMode.held(unseen: $unseen)';
}
