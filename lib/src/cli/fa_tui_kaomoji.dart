// The busy row's kaomoji thinking indicator (issue #1374): TUI-side
// rendering of the shared face set (lib/src/kaomoji_faces.dart — the
// faces, palette and swap cadence the app/web hosts render too). Data +
// render helpers for the busy row; the model state (face index, picker
// seam, swap cadence) lives in FaTuiModel. Same library, so the private
// members stay private — mirrors the fa_tui_heartbeat.dart split.
part of 'fa_tui.dart';

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
