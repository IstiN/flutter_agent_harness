// Goldens for issue #458: tool-output card height discipline — the
// clamped 3-line preview with the "+N lines" hint, the expanded card
// (full output after tapping the hint), and a failed result expanded to
// the error cap. Each state in light + dark on the phone frame, pumped
// through the shared golden helper so real bundled fonts render.
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/chat_message_tile.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// A realistic 40-line `bash` output: clamped to 3 lines + "+37 lines".
final _bashOutput = [
  for (var i = 1; i <= 40; i++)
    'flutter analyze --no-fatal-infos  •  issue $i: no problems found!',
].join('\n');

Future<void> _pump(
  WidgetTester tester,
  FaChatMessage message, {
  required ThemeData theme,
}) async {
  await pumpGolden(
    tester,
    Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ChatMessageTile(
          message: message,
          images: SandboxImageResolver(MemoryExecutionEnv()),
        ),
      ),
    ),
    size: goldenSizePhone,
    theme: theme,
  );
}

void main() {
  setUpAll(ensureGoldenFonts);

  FaChatMessage tool({required bool isError}) => FaChatMessage(
    role: 'tool',
    content: _bashOutput,
    toolName: 'bash',
    isError: isError,
  );

  for (final (name, theme) in [
    ('issue458_tool_card_clamp', buildFahTheme()),
    ('issue458_tool_card_clamp_light', buildFahThemeLight()),
  ]) {
    testWidgets('clamp default ($name)', (tester) async {
      await _pump(tester, tool(isError: false), theme: theme);
      expect(find.text('+37 lines'), findsOneWidget);
      await expectGolden(tester, name);
    });
  }

  for (final (name, theme) in [
    ('issue458_tool_card_expand', buildFahTheme()),
    ('issue458_tool_card_expand_light', buildFahThemeLight()),
  ]) {
    testWidgets('expanded ($name)', (tester) async {
      await _pump(tester, tool(isError: false), theme: theme);
      await tester.tap(find.text('+37 lines'));
      await tester.pumpAndSettle();
      expect(find.textContaining('issue 40'), findsOneWidget);
      await expectGolden(tester, name);
    });
  }

  for (final (name, theme) in [
    ('issue458_tool_card_error', buildFahTheme()),
    ('issue458_tool_card_error_light', buildFahThemeLight()),
  ]) {
    testWidgets('error expanded to cap ($name)', (tester) async {
      await _pump(tester, tool(isError: true), theme: theme);
      // No tap: failed results open expanded at the error cap.
      expect(find.textContaining('issue 40'), findsOneWidget);
      expect(find.text('Show less'), findsOneWidget);
      await expectGolden(tester, name);
    });
  }
}
