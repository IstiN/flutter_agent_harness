// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2472 — the model-facing `m<N>` record tags a model echoed into its
/// replies never render in the chat surface: the fa_ui projection strips
/// them from assistant rows (history loads AND the live tile feed through
/// it), while a user-typed `m2 …` quote renders verbatim.
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:fa_ui/src/chat/chat_message_projection.dart'
    show projectFaChatMessages;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

class _Service extends FakeChatService {
  _Service(this.msgs);

  final List<FaChatMessage> msgs;

  @override
  List<FaChatMessage> get messages => msgs;

  @override
  final List<String> pendingSteerTexts = [];
}

void main() {
  group(
    'projectFaChatMessages strips echoed record tags from assistant rows',
    () {
      test('an echoed tag prefix leaves the projected text', () {
        final projected = projectFaChatMessages([
          FaChatMessage(
            role: 'assistant',
            content: 'm1482 Принято. Ставлю ватч',
          ),
        ]);
        final text = (projected.single as dynamic).text as String;
        expect(text, 'Принято. Ставлю ватч');
      });

      test('multi-line echoes strip per line', () {
        final projected = projectFaChatMessages([
          FaChatMessage(
            role: 'assistant',
            content: 'm1482 Один\nm1494\nm1510 Два',
          ),
        ]);
        expect((projected.single as dynamic).text, 'Один\nm1494\nДва');
      });

      test('a user-typed m2 quote is projected verbatim', () {
        final projected = projectFaChatMessages([
          FaChatMessage(role: 'user', content: 'm2 what does this alias mean?'),
        ]);
        expect(
          (projected.single as dynamic).text,
          'm2 what does this alias mean?',
        );
      });
    },
  );

  group('the rendered chat surface never paints an echoed tag', () {
    Future<void> pump(WidgetTester tester, _Service service) async {
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: FaChatScreen(service: service)),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('assistant bubble renders the clean text', (tester) async {
      await pump(
        tester,
        _Service([
          FaChatMessage(role: 'user', content: 'что по PR?'),
          FaChatMessage(
            role: 'assistant',
            content: 'm1482 Принято. Ставлю ватч на PR',
          ),
        ]),
      );
      expect(find.textContaining('Принято. Ставлю ватч'), findsOneWidget);
      expect(find.textContaining('m1482'), findsNothing);
    });

    testWidgets('a user-typed m2 quote renders verbatim', (tester) async {
      await pump(
        tester,
        _Service([
          FaChatMessage(role: 'user', content: 'm2 what does this alias mean?'),
        ]),
      );
      expect(
        find.textContaining('m2 what does this alias mean?'),
        findsOneWidget,
      );
    });
  });
}
