// Goldens for issue #458: tool-output card height discipline — the
// clamped 3-line preview with the "+N lines" hint, the expanded card
// (full output after tapping the hint), and a failed result expanded to
// the error cap. Each state in light + dark on the phone frame, pumped
// through the shared golden helper so real bundled fonts render.
// Covers the shared chat tile through flutter_app's re-export shim
// lib/ui/widgets/chat_message_tile.dart (golden_guard coverage entry).
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

Future<ChatMessageTile> _tile({required bool isError}) async => ChatMessageTile(
  message: FaChatMessage(
    role: 'tool',
    content: _bashOutput,
    toolName: 'bash',
    isError: isError,
  ),
  images: SandboxImageResolver(MemoryExecutionEnv()),
);

Future<void> _pump(
  WidgetTester tester,
  ChatMessageTile tile, {
  required ThemeData theme,
}) async {
  await pumpGolden(
    tester,
    Align(
      alignment: Alignment.topLeft,
      child: Padding(padding: const EdgeInsets.all(16), child: tile),
    ),
    size: goldenSizePhone,
    theme: theme,
  );
}

void main() {
  setUpAll(ensureGoldenFonts);

  testWidgets('clamp default (dark)', (tester) async {
    await _pump(tester, await _tile(isError: false), theme: buildFahTheme());
    expect(find.text('+37 lines'), findsOneWidget);
    await expectGolden(tester, 'issue458_tool_card_clamp');
  });

  testWidgets('clamp default (light)', (tester) async {
    await _pump(
      tester,
      await _tile(isError: false),
      theme: buildFahThemeLight(),
    );
    expect(find.text('+37 lines'), findsOneWidget);
    await expectGolden(tester, 'issue458_tool_card_clamp_light');
  });

  testWidgets('expanded (dark)', (tester) async {
    await _pump(tester, await _tile(isError: false), theme: buildFahTheme());
    await tester.tap(find.text('+37 lines'));
    await tester.pumpAndSettle();
    expect(find.textContaining('issue 40'), findsOneWidget);
    await expectGolden(tester, 'issue458_tool_card_expand');
  });

  testWidgets('expanded (light)', (tester) async {
    await _pump(
      tester,
      await _tile(isError: false),
      theme: buildFahThemeLight(),
    );
    await tester.tap(find.text('+37 lines'));
    await tester.pumpAndSettle();
    expect(find.textContaining('issue 40'), findsOneWidget);
    await expectGolden(tester, 'issue458_tool_card_expand_light');
  });

  testWidgets('error expanded to cap (dark)', (tester) async {
    await _pump(tester, await _tile(isError: true), theme: buildFahTheme());
    // No tap: failed results open expanded at the error cap.
    expect(find.textContaining('issue 40'), findsOneWidget);
    expect(find.text('Show less'), findsOneWidget);
    await expectGolden(tester, 'issue458_tool_card_error');
  });

  testWidgets('error expanded to cap (light)', (tester) async {
    await _pump(
      tester,
      await _tile(isError: true),
      theme: buildFahThemeLight(),
    );
    expect(find.textContaining('issue 40'), findsOneWidget);
    expect(find.text('Show less'), findsOneWidget);
    await expectGolden(tester, 'issue458_tool_card_error_light');
  });
}
