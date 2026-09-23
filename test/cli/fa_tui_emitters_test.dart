// Model-level tests for the OSC 11 background probe's auto light/dark tier
// (issue #804, review k6LCR): BackgroundColorMsg driven through
// FaTuiModel.update covers the detection branch end to end.
//
// Split from fa_tui_test.dart to respect its 2800-line static gate.
import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:test/test.dart';

void main() {
  FaTuiCallbacks callbacks() {
    return FaTuiCallbacks(
      onSubmit: (line, {images = const []}) async {},
      onModelSelected: (_) async {},
      buildSlashMenu: (_) => const [],
      buildModelMenu: (_, _) => const [],
      statusLine: () => 'test',
      prompt: 'fa> ',
    );
  }

  setUp(() {
    FaThemeController.instance
      ..reset()
      ..profile = ColorProfile.trueColor;
  });

  group('OSC 11 background probe drives the auto tier (issue #804)', () {
    test('a light terminal reply flips the boot-dark palette mid-session', () {
      // Boot armed dark (COLORFGBG said dark); the vendored program's OSC
      // 11 probe reports a white background through the model update.
      FaThemeController.instance.armAutoLightDark(colorfgbg: '15;0');
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = model.update(BackgroundColorMsg(0xffffff)).$1 as FaTuiModel;
      expect(FaThemeController.instance.currentName, 'ohmypi-light');
      // A dark reply swaps back to the default palette.
      model = model.update(BackgroundColorMsg(0x121212)).$1 as FaTuiModel;
      expect(FaThemeController.instance.currentName, kDefaultTuiTheme.name);
    });

    test('a dark reply on a dark boot changes nothing', () {
      FaThemeController.instance.armAutoLightDark(colorfgbg: '15;0');
      final model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      final (next, _) = model.update(BackgroundColorMsg(0x121212));
      expect(FaThemeController.instance.currentName, kDefaultTuiTheme.name);
      expect(next, same(model), reason: 'no swap, no cache reset');
    });
  });
}
