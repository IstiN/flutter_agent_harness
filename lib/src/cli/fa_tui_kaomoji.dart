// The busy row's kaomoji thinking indicator (issue #1374): the model-side
// face state (index, picker seam, swap cadence) and the FA_KAOMOJI_FACE
// pin. gh-1446 retired the TUI's face RENDERING (the busy row is plain
// text; motion lives in the status-line brand zone) — the app/web hosts
// still render the shared face set (lib/src/kaomoji_faces.dart). Same
// library, so the private members stay private — mirrors the
// fa_tui_heartbeat.dart split.
part of 'fa_tui.dart';

/// Face-zone width: the widest face is `o_o?` (4 cells). Every face pads
/// into this fixed zone so a swap never moves a column right of it
/// (the #365 fixed-cell rule).
const kKaomojiFaceZoneCells = 4;

/// Below this width the fixed busy-row zones used to stop fitting
/// (issue #1374's ASCII face fallback): gh-1446 retired the face render —
/// the constant stays only for the repo's fixture arithmetic.
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
