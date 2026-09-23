/// Hot theme swap (issue #276) — split out of `fa_tui.dart` to keep it
/// under the repo's 2800-line size gate. Same library (a `part of`), so
/// the extension sees FaTuiModel's private members (`_wrapCache`,
/// `_stickyFmtRows`).
part of 'fa_tui.dart';

/// Hot theme swap (issue #276): repaints every frame with the new
/// [TuiTheme.current] palette — wrap and sticky caches are dropped so no
/// stale-colored rows survive.
final class ThemeSwappedMsg extends Msg {
  const ThemeSwappedMsg();
}

extension FaTuiThemeSwap on FaTuiModel {
  /// Hot theme swap: drop the wrap + sticky caches (they hold rows painted
  /// with the OLD palette) and bump the frame nonce; the renderer's row
  /// diff then repaints every content row with the new colors. Frame-atomic
  /// in practice: palette reads happen between frames on the single update
  /// loop, so no torn half-themed frame is emitted.
  (Model, Cmd?) _handleThemeSwapped() {
    final next = copyWith()
      .._wrapCache = _WrapCache()
      .._stickyFmtRows = const []
      .._stickyFmtSource = null
      .._stickyFmtWidth = null;
    return (next, null);
  }

  /// OSC 11 background reply (issue #804): the vendored program probes
  /// the terminal background at startup and the decoded color arrives
  /// here. While the auto light/dark tier is armed (no explicit
  /// `tui.theme`), the reply re-resolves the palette — a light terminal
  /// upgrades the boot default to `ohmypi-light` right after the first
  /// frame; dark keeps it (no swap, no repaint).
  (Model, Cmd?) _handleBackgroundProbe(BackgroundColorMsg msg) {
    final controller = FaThemeController.instance;
    controller.measuredTerminalBg = RgbColor(
      (msg.rgb >> 16) & 0xff,
      (msg.rgb >> 8) & 0xff,
      msg.rgb & 0xff,
    );
    if (!controller.reapplyAutoLightDark()) return (this, null);
    return _handleThemeSwapped();
  }
}

extension FaTuiThemeSwapController on FaTuiController {
  /// Hot theme swap (issue #276): the `/theme` handler already flipped
  /// [TuiTheme.current]; this repaints every row with the new palette and
  /// drops the wrap/sticky caches so no old-colored rows survive.
  void applyTheme() => _send(const ThemeSwappedMsg());
}
