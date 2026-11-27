// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2411 — the ONE definition of "the newest real user turn" every
/// context-bounding tier protects: the user's own words, never a
/// harness-injected user-role record.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage _assistant() => AssistantMessage(
  content: const [TextContent(text: 'working')],
  api: 'test-api',
  provider: 'test-provider',
  model: 'm1',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

ToolResultMessage _result() => ToolResultMessage(
  toolCallId: 'c1',
  toolName: 'read',
  content: [TextContent(text: 'r' * 2000)],
  isError: false,
  timestamp: DateTime.utc(2026),
);

void main() {
  group('newestRealUserTurnIndex', () {
    test('the newest user-role message whose words are the user\'s own', () {
      final messages = <Message>[
        UserMessage.text('from network: You are a member of DAP channel'),
        UserMessage.text('hello what do you know about dmtools?'),
        _assistant(),
        _result(),
      ];
      // The incident: `messages.last` is the tool result; the question
      // sits two records back, behind a synthetic notice.
      expect(newestRealUserTurnIndex(messages), 1);
    });

    test('synthetic harness content is never the user turn', () {
      final messages = <Message>[
        UserMessage.text('fix the login crash'),
        UserMessage.text('<system-notice>background job done</system-notice>'),
        UserMessage.text('[widget button] clicked'),
        UserMessage.text('The following is a summary of a branch'),
      ];
      expect(newestRealUserTurnIndex(messages), 0);
      expect(
        newestRealUserTurnIndex(<Message>[UserMessage.text('[ext:mail] wake')]),
        -1,
      );
    });

    test('a tool-result-only tail or an empty list has none', () {
      expect(newestRealUserTurnIndex(<Message>[]), -1);
      expect(newestRealUserTurnIndex(<Message>[_assistant(), _result()]), -1);
    });

    test('blocks fold like the ledger does — an image-only turn is real', () {
      final messages = <Message>[
        UserMessage(
          content: const [
            TextContent(text: '   '),
            TextContent(text: 'look at this'),
          ],
          timestamp: DateTime.utc(2026),
        ),
        _assistant(),
      ];
      expect(newestRealUserTurnIndex(messages), 0);
    });
  });

  group('newestUserTurnRecordIds', () {
    late MemoryFileSystem fs;
    late JsonlSessionRepo repo;

    setUp(() {
      fs = MemoryFileSystem();
      repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
    });

    test(
      'the record id of the newest real user turn on a session path',
      () async {
        final session = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        await session.appendMessage(
          UserMessage.text('from network: You are a member of DAP channel'),
        );
        final first = await session.appendMessage(
          UserMessage.text('first ask'),
        );
        await session.appendMessage(_assistant());
        final second = await session.appendMessage(
          UserMessage.text('second ask'),
        );
        await session.appendMessage(_result());
        final path = await session.getBranch();

        expect(newestUserTurnRecordIds(path), {second});
        expect(newestUserTurnRecordIds(path.take(3).toList()), {
          first,
        }, reason: 'the newest real turn of the PREFIX');
      },
    );

    test('a branch with no real user turn protects nothing', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('<system-notice>x'));
      await session.appendMessage(_assistant());
      expect(newestUserTurnRecordIds(await session.getBranch()), isEmpty);
    });
  });
}
