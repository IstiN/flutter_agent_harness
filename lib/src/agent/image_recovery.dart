/// Session-scoped 413 image-payload recovery state (gh-1934) — the
/// persistent half of the recovery ladder.
///
/// A provider rejecting a request for SIZE (413-class,
/// `isPayloadTooLargeError`) must never end in an unusable session. The
/// ladder in the agent loop (see `agent_loop_image_recovery.dart`) adapts
/// the payload — pass 1 drops the oldest images under an adaptive byte
/// budget, pass 2 strips ALL images to placeholders — and this state holds
/// what survives the retry: the learned per-session budget (halved on
/// every 413 — the cap is measured, never hardcoded per provider), the
/// strip-all latch, and the one-shot model-visible recovery note.
///
/// The state is HOST-OWNED session state (the same pattern as
/// `imageCapLatches`): one instance lives on the `Agent` for the session's
/// runtime, consulted by every request build and mutated by the ladder.
/// Session-scoped v1 (the ticket's open question 1 recommendation) — the
/// learned cap is runtime-only, never persisted.
library;

import 'image_registry.dart';

/// Floor for the adaptive image byte budget: halving past this point buys
/// nothing (the payload is text-dominated by then) and a zero budget would
/// disable the budget math entirely.
const int imageRecoveryBudgetFloor = 64 * 1024;

/// The canonical recovery notice line (UI + payload note share the
/// format; hosts add their own styling): `[images] recovered from 413:
/// dropped N, stripped M`.
String imageRecoveryNoticeText({required int dropped, required int stripped}) =>
    '[images] recovered from 413: dropped $dropped, stripped $stripped';

/// The actionable failure line when the ladder exhausted: the provider
/// still refuses and the session cannot shrink further on its own.
String imageRecoveryFailedText(String providerError) =>
    '[images] 413 recovery failed: the provider still rejects requests '
    '($providerError) — switch provider or lower images.maxBytesPerRequest';

/// One recovery pass, surfaced to hosts through the notice seam. [pass]
/// is the ladder step (1 = budget drop, 2 = strip-all); [failed] marks
/// the single actionable exhaustion event.
final class ImageRecoveryEvent {
  const ImageRecoveryEvent({
    required this.pass,
    required this.dropped,
    required this.stripped,
    this.failed = false,
    this.providerError,
  });

  /// The ladder pass this notice describes (1 or 2).
  final int pass;

  /// Images dropped by the adaptive budget (pass 1 semantics).
  final int dropped;

  /// Image blocks stripped to placeholders (pass 2 semantics).
  final int stripped;

  /// Whether the ladder exhausted: the provider still refuses after both
  /// passes. Fired exactly once, then the ladder stands down.
  final bool failed;

  /// The raw provider error behind a [failed] event.
  final String? providerError;
}

/// Set by hosts that surface recovery passes (the CLI prints the dim
/// transcript line + logs to fa.log). Same pattern as
/// [imageCapLearnedNotice].
typedef ImageRecoveryNotice = void Function(ImageRecoveryEvent event);

/// The active recovery reporter — wired once by the host at boot.
ImageRecoveryNotice? imageRecoveryNotice;

/// The session-scoped 413 recovery state: the adaptive budget, the
/// strip-all latch, and the one-shot recovery note. Mutated by the loop's
/// ladder, read by every request build.
final class ImagePayloadRecoveryState {
  int? _learnedByteBudget;
  bool _noteArmed = false;
  int _armedPass = 0;
  int _lastDropped = 0;
  int _lastStripped = 0;
  int? _consumedPass;

  /// Whether the LAST observed request build carried image bytes the
  /// ladder could shed (gh-1934 review — the AC6 gate evaluates the
  /// REQUEST that was refused, never the transcript: the transcript keeps
  /// image bytes forever under the payload-only rewrite, so a
  /// transcript-shaped gate would re-run the ladder on every later 413 of
  /// a latched session). Conservative default `true`: until the first
  /// build is observed the ladder engages exactly as before; every real
  /// request build records the fact (`rewriteRequestImages`).
  bool lastPayloadCariedImages = true;

  /// The adaptive budget the session learned from 413 refusals
  /// (halving); null before the first 413.
  int? get learnedByteBudget => _learnedByteBudget;

  /// Image blocks the last observed build dropped by the adaptive byte
  /// budget (the counts the pass events and notices render).
  int get lastDropped => _lastDropped;

  /// Image blocks the last observed build stripped to placeholders.
  int get lastStripped => _lastStripped;

  /// Pass-2 latch: every image block — current message included — rides
  /// as a placeholder from now on. Once set it never clears for the
  /// session (the provider proved it cannot take image bytes).
  bool stripAll = false;

  /// Image content keys evicted by a recovery pass — they never ride
  /// again this session; every later build replaces them with the
  /// `[image dropped: …]` placeholder.
  final Set<String> evictedKeys = {};

  /// The effective image byte budget for a request build: the learned
  /// budget when it is lower than [configured] — the config value is
  /// still honored when IT is lower (AC5). A disabled configured budget
  /// (0) cannot raise the learned one, and a learned budget never sinks
  /// below [imageRecoveryBudgetFloor].
  int effectiveByteBudget(int configured) {
    final learned = _learnedByteBudget;
    if (learned == null) return configured;
    var effective = learned < imageRecoveryBudgetFloor
        ? imageRecoveryBudgetFloor
        : learned;
    if (configured > 0 && configured < effective) effective = configured;
    return effective;
  }

  /// One 413 arrived: halve the adaptive budget (learn the provider cap —
  /// measured, never a per-provider table). A disabled configured budget
  /// (0) seeds from the package default: the provider proved a cap
  /// exists, so the ladder must have something to halve.
  void halveBudget(int configured) {
    final base =
        _learnedByteBudget ??
        (configured > 0 ? configured : defaultMaxImageBytesPerRequest);
    final halved = (base / 2).floor();
    _learnedByteBudget = halved < imageRecoveryBudgetFloor
        ? imageRecoveryBudgetFloor
        : halved;
  }

  /// Records what one request build did with the images (called from the
  /// rewrite path on EVERY build while the state is attached — the
  /// image-free fast path included, so a text-only 413 can never read a
  /// stale image-carrying observation), so an armed note renders with the
  /// CURRENT build's counts and the 413 gate knows whether the refused
  /// payload carried image bytes at all.
  void observeBuild({
    required int dropped,
    required int stripped,
    bool carriedImages = true,
  }) {
    _lastDropped = dropped;
    _lastStripped = stripped;
    lastPayloadCariedImages = carriedImages;
  }

  /// Arms the model-visible recovery note for the NEXT request build —
  /// the retried request carries it, so the assistant answer can note the
  /// recovery (AC1).
  void armNote({required int pass}) {
    _noteArmed = true;
    _armedPass = pass;
  }

  /// Whether a note is armed (the ladder checks before retrying).
  bool get noteArmed => _noteArmed;

  /// The pass the armed note belongs to.
  int get armedPass => _armedPass;

  /// Renders + disarms the armed note (null when nothing is armed).
  /// Fires the host notice seam exactly once per pass with the same
  /// counts the payload note carries, and leaves the pass pending for
  /// [takeLoopEvent] (the loop-level event rides the same build with the
  /// same counts).
  String? consumeNote() {
    if (!_noteArmed) return null;
    _noteArmed = false;
    _consumedPass = _armedPass;
    imageRecoveryNotice?.call(
      ImageRecoveryEvent(
        pass: _armedPass,
        dropped: _lastDropped,
        stripped: _lastStripped,
      ),
    );
    return '${imageRecoveryNoticeText(dropped: _lastDropped, stripped: _lastStripped)} — the request exceeded the provider size limit; the dropped images '
        'are gone from this and later requests. Continue without them and '
        'treat them as unavailable.';
  }

  /// Disarms an armed recovery note WITHOUT consuming it (gh-1934
  /// review): the retry that would have carried it never streamed (the
  /// run aborted or was cancelled between the arm and the retry build),
  /// so a later unrelated request of the session must not ride the stale
  /// one-shot claim. Called when a streamed response ends — a note the
  /// retry consumed makes this a no-op.
  void disarmNote() {
    _noteArmed = false;
  }

  /// The loop-level event payload for the build that just consumed a pass
  /// note: `(pass, dropped, stripped)` — the real counts the rebuilt
  /// request rode. One-shot per build; null when no note was consumed
  /// (nothing armed, or already taken). The loop emits this as an
  /// [ImagePayloadRecoveryEvent] so the wire kind carries real per-pass
  /// data instead of only the zeroed exhaustion event (gh-1934 review).
  (int, int, int)? takeLoopEvent() {
    final pass = _consumedPass;
    if (pass == null) return null;
    _consumedPass = null;
    return (pass, _lastDropped, _lastStripped);
  }
}
