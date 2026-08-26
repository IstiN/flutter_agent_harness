import 'package:fa/services/agent_service.dart' show FahChatMessage;
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_media_controllers.dart';

/// AI message text selection: one drag must span paragraphs and code
/// blocks within a bubble (MarkdownBody's per-block selectable regions
/// cut the selection at every block boundary).
void main() {
  testWidgets('a drag selects text across paragraphs in one bubble', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        home: Scaffold(
          body: Center(
            child: ChatMessageTile(
              images: SandboxImageResolver(MemoryExecutionEnv(cwd: '/work')),
              message: FahChatMessage(
                role: 'assistant',
                content:
                    'First paragraph with some longer text to select.\n\n'
                    '```dart\nfinal x = 1;\n```\n\n'
                    'Third paragraph after the code block.',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Drag from the first paragraph across the following blocks.
    final firstParagraph = find.textContaining('First paragraph');
    expect(firstParagraph, findsOneWidget);
    final thirdParagraph = find.textContaining('Third paragraph');
    expect(thirdParagraph, findsOneWidget);

    final gesture = await tester.startGesture(
      tester.getTopLeft(firstParagraph) + const Offset(10, 5),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(kLongPressTimeout);
    await gesture.moveTo(
      tester.getBottomLeft(thirdParagraph) + const Offset(40, -2),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();

    // Exactly ONE SelectableRegion owns the whole bubble (not one per
    // Markdown block): the drag then spans paragraphs.
    expect(find.byType(SelectableRegion), findsOneWidget);
  });

  testWidgets('a tool tile carries a raw-copy button that copies the output', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        home: Scaffold(
          body: Center(
            child: ChatMessageTile(
              images: SandboxImageResolver(MemoryExecutionEnv(cwd: '/work')),
              message: FahChatMessage(
                role: 'tool',
                toolName: 'bash',
                content: 'line one of output\nline two of output',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The tool header carries the always-visible copy icon.
    final copyButton = find.byIcon(Icons.copy_rounded);
    expect(copyButton, findsOneWidget);

    await tester.tap(copyButton);
    await tester.pump();
    // Transient "copied" state: the icon flips to a check (the clipboard
    // write itself is platform-side; the flip proves the tap path ran).
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('a speak tool tile renders the inline audio player', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final env = MemoryExecutionEnv(cwd: '/work');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        home: Scaffold(
          body: Center(
            child: ChatMessageTile(
              images: SandboxImageResolver(env),
              audioControllerFactory: (bytes) => FakeAudioController(),
              message: FahChatMessage(
                role: 'tool',
                toolName: 'speak',
                content: 'Speech saved to generated/hello.mp3 (1234 bytes)',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SandboxAudioPlayer), findsOneWidget);
  });
}
