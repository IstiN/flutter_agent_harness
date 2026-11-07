// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
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

Future<void> _pump(WidgetTester tester, _Service service) async {
  tester.view.physicalSize = const Size(700, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: FaChatScreen(service: service)));
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('system notices across empty aborted turns form one group', (
    tester,
  ) async {
    final service = _Service([
      FaChatMessage(role: 'assistant', content: 'Working in the background.'),
      for (final minutes in [1054, 1074, 1095, 1116, 1137]) ...[
        FaChatMessage(
          // System notices are persisted as user messages. The screen must
          // classify their envelope, not paint them as blue user bubbles.
          role: 'user',
          content:
              '<system-notice>Waiting heartbeat: you have been waiting for '
              '$minutes min. Still pending: 3 background jobs.'
              '</system-notice>',
        ),
        if (minutes != 1137) FaChatMessage(role: 'assistant', content: ''),
      ],
    ]);
    await _pump(tester, service);

    final group = find.byKey(const ValueKey('faSystemNoticeGroup'));
    expect(group, findsOneWidget);
    expect(find.text('System notices · 5'), findsOneWidget);
    expect(find.textContaining('1137 min'), findsOneWidget);
    expect(find.textContaining('1054 min'), findsNothing);
    expect(find.textContaining('<system-notice>'), findsNothing);
    expect(tester.getSize(group).height, lessThan(120));
    await expectLater(
      group,
      matchesGoldenFile('goldens/system_notice_group.png'),
    );

    await tester.tap(group);
    await tester.pump();
    expect(find.textContaining('1054 min'), findsOneWidget);
    expect(find.textContaining('1074 min'), findsOneWidget);
    expect(find.textContaining('1137 min'), findsOneWidget);
  });

  testWidgets('a live notice append updates the existing group incrementally', (
    tester,
  ) async {
    final service = _Service([
      FaChatMessage(role: 'assistant', content: 'Waiting.'),
      FaChatMessage(
        role: 'user',
        content: '<system-notice>Heartbeat one.</system-notice>',
      ),
      FaChatMessage(role: 'assistant', content: ''),
    ]);
    await _pump(tester, service);
    expect(find.text('System notice'), findsOneWidget);

    service.msgs.add(
      FaChatMessage(
        role: 'user',
        content: '<system-notice>Heartbeat two.</system-notice>',
      ),
    );
    service.notifyListeners();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('faSystemNoticeGroup')), findsOneWidget);
    expect(find.text('System notices · 2'), findsOneWidget);
    expect(find.textContaining('Heartbeat two.'), findsOneWidget);
    expect(find.textContaining('Heartbeat one.'), findsNothing);
    expect(find.textContaining('<system-notice>'), findsNothing);
  });

  testWidgets('queued system notices do not spam pending user capsules', (
    tester,
  ) async {
    final service = _Service([]);
    service.pendingSteerTexts.addAll([
      '<system-notice>Waiting heartbeat: 1137 min.</system-notice>',
      'Please wrap up when the job finishes.',
      '<system-notice>Background shell job sh-1 finished.</system-notice>',
    ]);
    await _pump(tester, service);

    expect(find.byKey(const ValueKey('faSystemNoticeGroup')), findsOneWidget);
    expect(find.text('System notices · 2'), findsOneWidget);
    expect(find.text('Please wrap up when the job finishes.'), findsOneWidget);
    expect(find.textContaining('<system-notice>'), findsNothing);
  });

  testWidgets('an obligations ledger becomes a structured task summary', (
    tester,
  ) async {
    const older =
        'Check Quality run 42014907766 on epam/dmtools-dart#480 and merge '
        'once green.';
    const latest =
        'Check Quality run 42019004551 on epam/dmtools-dart#480 '
        '(feat/jira-get-issue-types) and merge once green.';
    final service = _Service([
      FaChatMessage(
        role: 'user',
        content:
            '<system-notice>obligations ledger (engine-maintained; '
            'verbatim quotes with their source record): '
            '- [open] pending-wait: $older '
            '(id 01-old, record 0035_old) '
            '- [open] pending-wait: $latest '
            '(id 01-new, record 0036_new) '
            '- [open] pending-wait: $latest '
            '(id 01-repeat, record 0037_repeat) '
            '… and 4 more open obligations (read the ledger record for the '
            'full list)</system-notice>',
      ),
    ]);
    await _pump(tester, service);

    final group = find.byKey(const ValueKey('faSystemNoticeGroup'));
    expect(find.text('Open obligations · 7'), findsOneWidget);
    expect(find.text(latest), findsOneWidget);
    expect(find.text(older), findsNothing);
    expect(find.textContaining('obligations ledger'), findsNothing);
    expect(find.textContaining('(id '), findsNothing);
    await expectLater(
      group,
      matchesGoldenFile('goldens/obligations_notice_group.png'),
    );

    await tester.tap(group);
    await tester.pump();
    expect(find.text('Pending wait'), findsNWidgets(2));
    expect(find.text(latest), findsOneWidget);
    expect(find.text(older), findsOneWidget);
    expect(find.text('×2'), findsOneWidget);
    expect(find.text('4 more in the session ledger'), findsOneWidget);
    expect(find.textContaining('01-repeat'), findsNothing);
    await expectLater(
      group,
      matchesGoldenFile('goldens/obligations_notice_group_expanded.png'),
    );
  });

  testWidgets('a malformed ledger keeps the ordinary notice fallback', (
    tester,
  ) async {
    final service = _Service([
      FaChatMessage(
        role: 'user',
        content:
            '<system-notice>obligations ledger (unparseable)'
            '</system-notice>',
      ),
    ]);
    await _pump(tester, service);

    expect(find.text('System notice'), findsOneWidget);
    expect(find.textContaining('obligations ledger'), findsOneWidget);
    expect(find.textContaining('Open obligations'), findsNothing);
  });

  testWidgets('an empty final assistant record leaves no bubble', (
    tester,
  ) async {
    final service = _Service([
      FaChatMessage(role: 'user', content: 'Finish the task'),
      // The reported session tail is an aborted assistant record carrying
      // only thinking; its UI projection is exactly this empty text row.
      FaChatMessage(role: 'assistant', content: ''),
    ]);
    await _pump(tester, service);

    final empty = find.byWidgetPredicate(
      (widget) => widget is ChatMessageTile && widget.message.content.isEmpty,
    );
    expect(empty, findsOneWidget);
    expect(tester.getSize(empty), Size.zero);
    expect(find.byType(MarkdownBody), findsOneWidget);
  });
}
