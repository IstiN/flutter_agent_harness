// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Host-locked golden coverage is separate from the portable behavioural
// suite: CI's fa_ui shard selector excludes paths containing `golden`.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

class _Service extends FakeChatService {
  _Service(this.msgs);

  final List<FaChatMessage> msgs;

  @override
  List<FaChatMessage> get messages => msgs;
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
  testWidgets('collapsed system notice group golden', (tester) async {
    final service = _Service([
      FaChatMessage(role: 'assistant', content: 'Working in the background.'),
      for (final minutes in [1054, 1074, 1095, 1116, 1137]) ...[
        FaChatMessage(
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
    expect(tester.getSize(group).height, lessThan(120));
    await expectLater(
      group,
      matchesGoldenFile('goldens/system_notice_group.png'),
    );
  });

  testWidgets('obligations notice group golden', (tester) async {
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
    expect(group, findsOneWidget);
    expect(find.text('Open obligations · 7'), findsOneWidget);
    await expectLater(
      group,
      matchesGoldenFile('goldens/obligations_notice_group.png'),
    );

    await tester.tap(group);
    await tester.pump();
    expect(find.text('Pending wait'), findsNWidgets(2));
    expect(find.text('4 more in the session ledger'), findsOneWidget);
    await expectLater(
      group,
      matchesGoldenFile('goldens/obligations_notice_group_expanded.png'),
    );
  });
}
