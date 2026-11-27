// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The host-quota terminal notice card tests (gh-2391): the marker renders
/// the dedicated card with the optional HTTPS link; non-HTTPS or missing
/// links never render a button, and the raw marker never leaks into text.
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) {
  return FaUiThemeProvider(
    data: const FaUiTheme(),
    child: MaterialApp(
      theme: buildFahTheme(),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

ChatMessageTile _tile(String content) => ChatMessageTile(
  message: FaChatMessage(
    role: 'tool',
    content: content,
    isError: true,
    toolName: 'error',
  ),
  images: SandboxImageResolver(MemoryExecutionEnv()),
);

void main() {
  group('hostQuotaLinkFrom / stripHostQuotaMarker', () {
    test('parses the HTTPS link and strips the marker', () {
      const content =
          '[[host-quota:https://app.example/allowance]] Allowance used up.';
      expect(
        hostQuotaLinkFrom(content),
        Uri.parse('https://app.example/allowance'),
      );
      expect(stripHostQuotaMarker(content), 'Allowance used up.');
    });

    test('no marker or an empty link parses to null', () {
      expect(hostQuotaLinkFrom('plain error'), isNull);
      expect(hostQuotaLinkFrom('[[host-quota:]]'), isNull);
    });

    test('a non-HTTPS link never resolves (E11: nothing else is opened)', () {
      expect(hostQuotaLinkFrom('[[host-quota:http://evil.example/]]'), isNull);
      expect(hostQuotaLinkFrom('[[host-quota:javascript:alert(1)]]'), isNull);
    });
  });

  group('the host-quota card', () {
    testWidgets('renders the notice with the link for an HTTPS marker', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(_tile('[[host-quota:https://app.example/allowance]]')),
      );
      expect(find.text('Out of allowance'), findsOneWidget);
      expect(find.text('Open allowance page'), findsOneWidget);
      // The raw marker never leaks into the rendered text.
      expect(find.textContaining('host-quota'), findsNothing);
    });

    testWidgets('a link-less marker renders the card without a button', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_tile('[[host-quota:]]')));
      expect(find.text('Out of allowance'), findsOneWidget);
      expect(find.text('Open allowance page'), findsNothing);
    });

    testWidgets('a plain 429 keeps the generic error tile', (tester) async {
      await tester.pumpWidget(
        _wrap(_tile('429: {"error":{"code":"server_busy"}}')),
      );
      expect(find.text('Out of allowance'), findsNothing);
    });
  });
}
