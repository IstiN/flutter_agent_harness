// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

final class _DraftChatService extends FakeChatService {
  final sentTexts = <String>[];
  final sentAttachments = <List<FaStagedAttachment>>[];

  bool get hasComposerListener => hasListeners;

  @override
  Future<void> sendText(String text) async {
    sentTexts.add(text);
  }

  @override
  Future<void> sendAttachments({
    required List<FaStagedAttachment> attachments,
    String text = '',
  }) async {
    sentTexts.add(text);
    sentAttachments.add(attachments);
  }
}

Future<void> _pumpComposer(
  WidgetTester tester,
  _DraftChatService service,
  ChatComposerDraftStore store,
  String draftKey,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatComposer(
          service: service,
          draftKey: draftKey,
          draftStore: store,
          autofocus: false,
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _stage(WidgetTester tester, String name, Uint8List bytes) async {
  await tester
      .state<ChatComposerState>(find.byType(ChatComposer))
      .stageDroppedFiles([(name: name, bytes: bytes, mimeType: 'text/plain')]);
  await tester.pump();
}

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  testWidgets('switching services isolates and restores text and attachment '
      'bytes, name, path, and mime type', (tester) async {
    final store = ChatComposerDraftStore();
    final a = _DraftChatService();
    final b = _DraftChatService();
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    await _pumpComposer(tester, a, store, 'session-a');
    await tester.enterText(find.byType(TextField), 'draft for A');
    await _stage(tester, 'a-notes.txt', bytes);
    expect(a.hasComposerListener, isTrue);

    await _pumpComposer(tester, b, store, 'session-b');
    expect(a.hasComposerListener, isFalse);
    expect(b.hasComposerListener, isTrue);
    expect(_fieldText(tester), isEmpty);
    expect(find.byIcon(Icons.close), findsNothing);
    expect(store.draftFor('session-b').isEmpty, isTrue);

    await tester.enterText(find.byType(TextField), 'draft for B');
    await _pumpComposer(tester, a, store, 'session-a');
    expect(b.hasComposerListener, isFalse);
    expect(_fieldText(tester), 'draft for A');
    expect(find.textContaining('a-notes.txt'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);

    final attachment = store.draftFor('session-a').attachments.single;
    expect(attachment.name, 'a-notes.txt');
    expect(attachment.path, 'a-notes.txt');
    expect(attachment.bytes, same(bytes));
    expect(attachment.mimeType, mimeTypeForUploadName('a-notes.txt'));
    expect(store.draftFor('session-b').text, 'draft for B');

    await tester.pumpWidget(const SizedBox());
    expect(a.hasComposerListener, isFalse);
  });

  testWidgets('route-style unmount and remount restores the same draft only', (
    tester,
  ) async {
    final store = ChatComposerDraftStore();
    final a = _DraftChatService();
    final b = _DraftChatService();

    await _pumpComposer(tester, a, store, 'session-a');
    await tester.enterText(find.byType(TextField), 'survives the apps route');
    await _stage(tester, 'route.bin', Uint8List.fromList([9, 8, 7]));

    // The narrow shell replaces its chat route with the apps surface. A full
    // tree replacement exercises actual ChatComposer disposal, not offstage.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Apps'))),
    );
    expect(find.byType(ChatComposer), findsNothing);
    expect(a.hasComposerListener, isFalse);

    await _pumpComposer(tester, b, store, 'session-b');
    expect(_fieldText(tester), isEmpty);
    expect(find.byIcon(Icons.close), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Apps'))),
    );
    await _pumpComposer(tester, a, store, 'session-a');
    expect(_fieldText(tester), 'survives the apps route');
    expect(find.textContaining('route.bin'), findsOneWidget);
    expect(store.draftFor('session-a').attachments.single.bytes, [9, 8, 7]);
  });

  testWidgets('successful send clears only its owning draft', (tester) async {
    final store = ChatComposerDraftStore();
    final a = _DraftChatService();
    final b = _DraftChatService();

    await _pumpComposer(tester, a, store, 'session-a');
    await tester.enterText(find.byType(TextField), 'send from A');
    await _stage(tester, 'send-a.txt', Uint8List.fromList([4, 5, 6]));

    await _pumpComposer(tester, b, store, 'session-b');
    await tester.enterText(find.byType(TextField), 'keep B');
    await _stage(tester, 'keep-b.txt', Uint8List.fromList([7]));

    await _pumpComposer(tester, a, store, 'session-a');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();

    expect(a.sentTexts, ['send from A']);
    expect(a.sentAttachments.single.single.path, 'send-a.txt');
    expect(a.sentAttachments.single.single.bytes, [4, 5, 6]);
    expect(
      a.sentAttachments.single.single.mimeType,
      mimeTypeForUploadName('send-a.txt'),
    );
    expect(b.sentTexts, isEmpty);
    expect(store.draftFor('session-a').isEmpty, isTrue);
    expect(store.draftFor('session-b').text, 'keep B');
    expect(store.draftFor('session-b').attachments.single.name, 'keep-b.txt');

    await _pumpComposer(tester, b, store, 'session-b');
    expect(_fieldText(tester), 'keep B');
    expect(find.textContaining('keep-b.txt'), findsOneWidget);

    await _pumpComposer(tester, a, store, 'session-a');
    expect(_fieldText(tester), isEmpty);
    expect(find.byIcon(Icons.close), findsNothing);
  });
}
