// The busy row's kaomoji thinking indicator (issue #1374): eight
// owner-approved two-tone faces replacing the braille spinner. Data +
// render helpers for the busy row; the model state (face index, picker
// seam, swap cadence) lives in FaTuiModel. Same library, so the private
// members stay private — mirrors the fa_tui_heartbeat.dart split.
part of 'fa_tui.dart';

/// One styled run of a kaomoji face: the text and whether it is a mouth
/// (blue #70a0e0) — everything else is an eye/face stroke (teal #60d0d0),
/// per the approved SVG sprite's `.t`/`.b` classes (issue #1374).
typedef KaomojiRun = (String text, bool mouth);

/// One kaomoji face: the primary runs and the ASCII-safe fallback runs
/// (narrow terminals, fonts without ◕‿¬). Faces whose primary text is
/// already ASCII carry the same runs twice.
final class KaomojiFace {
  const KaomojiFace(this.runs, this.fallbackRuns);

  final List<KaomojiRun> runs;
  final List<KaomojiRun> fallbackRuns;

  List<KaomojiRun> runsFor(bool ascii) => ascii ? fallbackRuns : runs;
}

/// The eight approved faces, in the issue's order. Segmentation mirrors
/// the SVG: `¬_¬`'s ASCII fallback `-_/` flattens both eyes to strokes
/// and the tilted stroke becomes the mouth; `o_o?`'s fallback drops the
/// curious `?`.
const List<KaomojiFace> kKaomojiFaces = [
  KaomojiFace(
    [('>', false), ('_', true), ('o', false)],
    [('>', false), ('_', true), ('o', false)],
  ),
  KaomojiFace(
    [('-', false), ('_', true), ('-', false)],
    [('-', false), ('_', true), ('-', false)],
  ),
  KaomojiFace(
    [('o', false), ('_', true), ('o', false)],
    [('o', false), ('_', true), ('o', false)],
  ),
  KaomojiFace(
    [('>', false), ('_', true), ('<', false)],
    [('>', false), ('_', true), ('<', false)],
  ),
  KaomojiFace(
    [('o', false), ('_', true), ('<', false)],
    [('o', false), ('_', true), ('<', false)],
  ),
  KaomojiFace(
    [('◕', false), ('‿', true), ('◕', false)],
    [('^', false), ('.', true), ('^', false)],
  ),
  KaomojiFace(
    [('¬', false), ('_', true), ('¬', false)],
    [('-', false), ('_', false), ('/', true)],
  ),
  KaomojiFace(
    [('o', false), ('_', true), ('o', false), ('?', true)],
    [('o', false), ('_', true), ('o', false)],
  ),
];

/// The face swaps every [kKaomojiSwapTicks] spinner ticks — 9 × 100 ms ≈
/// the issue's 0.9 s cadence — with a RANDOM pick, never a rotation.
const kKaomojiSwapTicks = 9;

/// Face-zone width: the widest face is `o_o?` (4 cells). Every face pads
/// into this fixed zone so a swap never moves a column right of it
/// (the #365 fixed-cell rule).
const kKaomojiFaceZoneCells = 4;

/// Below this width the fixed busy-row zones stop fitting, and cramped
/// terminals are also the likeliest to lack ◕‿¬ glyphs: render the
/// ASCII-safe fallback set (3 cells, 7-bit only).
const kKaomojiAsciiMinWidth = 36;

/// The process-wide random source of the default picker. Never read at a
/// call site — [FaTuiModel.kaomojiPick] is the seam; tests inject a
/// deterministic function instead.
final _kaomojiRandom = math.Random();

/// The default face picker: the `FA_KAOMOJI_FACE` pin when set (the
/// visual-fixture seam — every pick returns the pinned index), else a
/// uniform process-random pick.
int _defaultKaomojiPick(int max) {
  final pin = _kaomojiFacePin();
  return pin == null ? _kaomojiRandom.nextInt(max) : pin.clamp(0, max - 1);
}

/// The active `FA_KAOMOJI_FACE` pin: [FaTuiModel.kaomojiFacePinOverride]
/// wins (env is immutable in-process, so tests override statically), then
/// the env var, clamped into the face set; null = unpinned (the
/// production random cadence).
int? _kaomojiFacePin() {
  final override = FaTuiModel.kaomojiFacePinOverride;
  if (override != null) return override;
  final pin = int.tryParse(Platform.environment['FA_KAOMOJI_FACE'] ?? '');
  return pin?.clamp(0, kKaomojiFaces.length - 1);
}

/// Uniform over every face EXCEPT [current]: a swap that lands back on
/// the same face reads as a frozen row, so the raw pick in `0…len-2`
/// skips over [current]'s index.
int _nextKaomojiIndex(int Function(int max) pick, int current) {
  final raw = pick(kKaomojiFaces.length - 1);
  return raw >= current ? raw + 1 : raw;
}

/// The face's plain text (its exact cell count — every glyph is one
/// BMP code unit).
String _kaomojiPlainText(KaomojiFace face, bool ascii) {
  final b = StringBuffer();
  for (final (text, _) in face.runsFor(ascii)) {
    b.write(text);
  }
  return b.toString();
}

/// The face rendered two-tone: eye/face strokes in the brand teal, mouths
/// in the brand blue (issue #1374), through the theme controller's
/// profile-aware emitters.
String _kaomojiColored(KaomojiFace face, bool ascii) {
  final b = StringBuffer();
  for (final (text, mouth) in face.runsFor(ascii)) {
    b.write(mouth ? tuiKaomojiMouth(text) : tuiKaomojiEye(text));
  }
  return b.toString();
}
