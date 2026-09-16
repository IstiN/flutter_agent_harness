// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SandboxImageResolver images() => SandboxImageResolver(MemoryExecutionEnv());

  Widget wrap(Widget child, {FaUiTheme? uiTheme}) {
    return FaUiThemeProvider(
      data: uiTheme ?? const FaUiTheme(),
      child: MaterialApp(
        theme: buildFahTheme(),
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  testWidgets('assistant bubble shows the avatarBuilder widget', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        ChatMessageTile(
          message: FaChatMessage(role: 'assistant', content: 'hello'),
          images: images(),
          avatarBuilder: (context, role) =>
              role == 'assistant' ? const Text('AV') : null,
        ),
      ),
    );
    expect(find.text('AV'), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('no avatarBuilder renders the stock default avatar bubble', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        ChatMessageTile(
          message: FaChatMessage(role: 'assistant', content: 'hello'),
          images: images(),
        ),
      ),
    );
    expect(find.text('hello'), findsOneWidget);
    // The stock avatar is the Fa brand `>_` tile.
    expect(find.byType(FaAiAvatar), findsOneWidget);
  });

  testWidgets('surface tokens re-seat the bubble and keep the stock border', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        ChatMessageTile(
          message: FaChatMessage(role: 'assistant', content: 'hello'),
          images: images(),
        ),
        uiTheme: const FaUiTheme(
          background: Color(0xFF0B0B0F),
          surface: Color(0xFF13131A),
        ),
      ),
    );
    final container = tester.widget<Container>(
      find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).color == const Color(0xFF13131A),
      ),
    );
    final decoration = container.decoration! as BoxDecoration;
    // The border follows the ambient divider color (== the stock border in
    // the Fa theme).
    expect(
      (decoration.border! as Border).top.color,
      buildFahTheme().dividerColor,
    );
  });

  testWidgets(
    'tool tile with codemie auth-expired marker shows the recovery card',
    (tester) async {
      String? recoveredProvider;
      await tester.pumpWidget(
        wrap(
          ChatMessageTile(
            message: FaChatMessage(
              role: 'tool',
              content:
                  'CodeMie session expired — the endpoint redirected the '
                  'request to the SSO login portal. Re-authorize to refresh '
                  'the token. [[auth-expired:codemie]]',
              toolName: 'web_search',
              isError: true,
            ),
            images: images(),
            onAuthRecovery: (provider) => recoveredProvider = provider,
          ),
        ),
      );

      // The auth-expired badge.
      expect(find.text('Session expired'), findsOneWidget);

      // The provider name in the title.
      expect(find.text('Your codemie session has expired.'), findsOneWidget);

      // The Authorize button (triggers the callback with 'codemie').
      expect(find.widgetWithText(FilledButton, 'Authorize'), findsOneWidget);
      await tester.tap(find.text('Authorize'));
      expect(recoveredProvider, 'codemie');
    },
  );

  testWidgets(
    'auth-expired card strips the marker from the visible body text',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          ChatMessageTile(
            message: FaChatMessage(
              role: 'tool',
              content:
                  'CodeMie session expired — the endpoint redirected the '
                  'request to the SSO login portal. Re-authorize to refresh '
                  'the token. [[auth-expired:codemie]]',
              toolName: 'web_search',
              isError: true,
            ),
            images: images(),
          ),
        ),
      );

      // The marker itself must not appear in the body.
      expect(find.textContaining('[[auth-expired:codemie]]'), findsNothing);

      // The human-readable part is still shown.
      expect(find.textContaining('CodeMie session expired'), findsOneWidget);
    },
  );

  testWidgets(
    'plain tool error (no auth marker) renders as a normal tile, not a card',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          ChatMessageTile(
            message: FaChatMessage(
              role: 'tool',
              content: 'Something went wrong.',
              toolName: 'bash',
              isError: true,
            ),
            images: images(),
          ),
        ),
      );

      // No auth-expired badge should appear.
      expect(find.text('Session expired'), findsNothing);

      // The error text renders normally.
      expect(find.text('Something went wrong.'), findsOneWidget);

      // No Authorize button.
      expect(find.text('Authorize'), findsNothing);
    },
  );

  test('fahChatColorsOf maps the surface tokens onto the chat palette', () {
    const stock = FahColors.dark;
    final reseated = stock.withSurfaces(
      background: const Color(0xFF0B0B0F),
      surface: const Color(0xFF13131A),
    );
    expect(reseated.bg, const Color(0xFF0B0B0F));
    expect(reseated.panel, const Color(0xFF13131A));
    expect(reseated.panelAlt, const Color(0xFF13131A));
    // Untouched fields stay stock.
    expect(reseated.text, stock.text);
    expect(reseated.border, stock.border);
    // An all-null call is pixel-identical.
    final identicalCopy = stock.withSurfaces();
    expect(identicalCopy.bg, stock.bg);
    expect(identicalCopy.panel, stock.panel);
  });

  testWidgets('a non-permission tool whose body text happens to mention '
      '"X access required" stays on the normal collapsible tile', (
    tester,
  ) async {
    // Skill bodies (e.g. js-apps/SKILL.md) document the permission flows,
    // so a `read` result containing the string "Calendar access required"
    // used to be hijacked by the permission-card heuristic.
    await tester.pumpWidget(
      wrap(
        ChatMessageTile(
          message: FaChatMessage(
            role: 'tool',
            content:
                '1. Open the app.\n'
                '2. When prompted "Calendar access required", grant.\n'
                '3. Continue.\n'
                '${List.generate(15, (i) => 'step detail $i').join('\n')}',
            toolName: 'read',
            isError: false,
          ),
          images: images(),
        ),
      ),
    );

    // The orange permission badge must NOT appear (the tool isn't a
    // permission-needing one).
    expect(find.text('Calendar access required'), findsNothing);

    // No permission action buttons.
    expect(find.text('Open Settings'), findsNothing);
    expect(find.text('Try again'), findsNothing);

    // The collapsible tile stays — 18 lines clamp to a 3-line preview
    // with the "+15 lines" hint (issue #458).
    expect(find.text('+15 lines'), findsOneWidget);
  });

  testWidgets(
    'a calendar_events result that is actually a permission denial still '
    'renders the orange permission card with action buttons',
    (tester) async {
      String? permission;
      String? action;
      await tester.pumpWidget(
        wrap(
          ChatMessageTile(
            message: FaChatMessage(
              role: 'tool',
              content:
                  'Calendar access denied — open System Settings → Privacy → '
                  'Calendars to grant access, then try again.',
              toolName: 'calendar_events',
              isError: true,
            ),
            images: images(),
            onPermissionAction: (perm, act) {
              permission = perm;
              action = act;
            },
          ),
        ),
      );

      // The permission card surfaces with its orange badge + body.
      expect(find.text('Calendar access required'), findsOneWidget);
      expect(find.textContaining('System Settings'), findsOneWidget);

      // The "Open Settings" button routes the callback with permission +
      // the action it represents.
      expect(
        find.widgetWithText(FilledButton, 'Open Settings'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Open Settings'));
      expect(permission, 'Calendar');
      expect(action, isNotNull);
    },
  );
  testWidgets('a 40-line tool result clamps to 3 lines with a "+37 lines" '
      'hint; height independent of output length (AC1)', (tester) async {
    Widget tile(int lines) => wrap(
      ChatMessageTile(
        message: FaChatMessage(
          role: 'tool',
          content: [
            for (var i = 1; i <= lines; i++) 'output line $i',
          ].join('\n'),
          toolName: 'bash',
        ),
        images: images(),
      ),
    );

    await tester.pumpWidget(tile(40));
    // First three lines only — cut on line boundaries.
    expect(
      find.text('output line 1\noutput line 2\noutput line 3'),
      findsOneWidget,
    );
    expect(find.text('output line 4'), findsNothing);
    expect(find.text('output line 39'), findsNothing);
    // The hint names the hidden remainder.
    expect(find.text('+37 lines'), findsOneWidget);

    final clampedHeight = tester.getSize(find.byType(ChatMessageTile)).height;
    await tester.pumpWidget(tile(400));
    expect(find.text('+397 lines'), findsOneWidget);
    // Same preview + same hint → identical collapsed height.
    expect(tester.getSize(find.byType(ChatMessageTile)).height, clampedHeight);
  });

  testWidgets('expand shows the full output, collapse returns to the clamp, '
      'and the state is per card (AC2)', (tester) async {
    String output(int lines) =>
        [for (var i = 1; i <= lines; i++) 'output line $i'].join('\n');
    ChatMessageTile tile() => ChatMessageTile(
      // 8 lines: clamped, yet two expanded cards still fit the test
      // viewport — this test is about per-card state, not the cap.
      message: FaChatMessage(role: 'tool', content: output(8), toolName: 'bash'),
      images: images(),
    );
    await tester.pumpWidget(wrap(Column(children: [tile(), tile()])));
    expect(find.text('+5 lines'), findsNWidgets(2));

    // Expand only the first card.
    await tester.tap(find.text('+5 lines').first);
    await tester.pump();
    expect(find.textContaining('output line 8'), findsOneWidget);
    expect(find.text('Show less'), findsOneWidget);
    // The second card is still clamped — state is per instance.
    expect(find.text('+5 lines'), findsOneWidget);

    // Collapse back.
    await tester.tap(find.text('Show less'));
    await tester.pump();
    expect(find.textContaining('output line 8'), findsNothing);
    expect(find.text('+5 lines'), findsNWidgets(2));
  });

  testWidgets('a 250-line expanded result scrolls instead of growing '
      'without bound (AC2 hard max)', (tester) async {
    await tester.pumpWidget(
      wrap(
        ChatMessageTile(
          message: FaChatMessage(
            role: 'tool',
            content: [
              for (var i = 1; i <= 250; i++) 'output line $i',
            ].join('\n'),
            toolName: 'bash',
          ),
          images: images(),
        ),
      ),
    );
    await tester.tap(find.text('+247 lines'));
    await tester.pump();
    // The full body is in the tree; the card scrolls past the line cap.
    expect(find.textContaining('output line 250'), findsOneWidget);
    expect(find.byType(Scrollable), findsOneWidget);
  });

  testWidgets('a failed tool call starts expanded at the error cap; the '
      'same body on a success stays clamped (AC3)', (tester) async {
    Widget tile({required bool isError}) => wrap(
      ChatMessageTile(
        message: FaChatMessage(
          role: 'tool',
          content: [
            for (var i = 1; i <= 40; i++) 'output line $i',
          ].join('\n'),
          toolName: 'bash',
          isError: isError,
        ),
        images: images(),
      ),
    );

    await tester.pumpWidget(tile(isError: false));
    expect(find.textContaining('output line 10'), findsNothing);
    expect(find.text('+37 lines'), findsOneWidget);

    await tester.pumpWidget(tile(isError: true));
    // Expanded by default — no clamp hint, Show less offered instead.
    expect(find.textContaining('output line 10'), findsOneWidget);
    expect(find.text('+37 lines'), findsNothing);
    expect(find.text('Show less'), findsOneWidget);
  });

  testWidgets('empty tool output renders the "(no output)" stub, no clamp '
      'UI', (tester) async {
    await tester.pumpWidget(
      wrap(
        ChatMessageTile(
          message: FaChatMessage(role: 'tool', content: '', toolName: 'edit'),
          images: images(),
        ),
      ),
    );
    expect(find.text('(no output)'), findsOneWidget);
    expect(find.text('Show more'), findsNothing);
  });

  testWidgets('a single very long line offers the toggle and never '
      'overflows the card (E1)', (tester) async {
    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 360,
          child: ChatMessageTile(
            message: FaChatMessage(
              role: 'tool',
              content: 'x' * 2000,
              toolName: 'bash',
            ),
            images: images(),
          ),
        ),
      ),
    );
    // maxLines clamps the wrapped line (no overflow exception) and the
    // toggle still offers the full text.
    expect(find.text('Show more'), findsOneWidget);
    await tester.tap(find.text('Show more'));
    await tester.pump();
    expect(find.text('x' * 2000), findsOneWidget);
  });

}
