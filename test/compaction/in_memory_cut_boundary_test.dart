// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// gh-2411 follow-up #5 (F3/R5): every IN-MEMORY cut hands the provider a
// context that opens on a user turn — never on an assistant or tool
// fragment whose user turn is gone (several APIs refuse the shape, and
// the model reads the missing turns as lost history). The local-trim
// valve is the one function behind all four valve sites (the resume boot
// cap, the over-window continuation, the emergency relief, the
// summarizer-down fallback); the hide-only relief's rebuilt projection is
// bounded by [cutAtUserTurnBoundary] on the host side.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/agent/auto_compactor.dart'
    show localTrimValve;
import 'package:test/test.dart';

AssistantMessage _answer(String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

ToolResultMessage _result(String id) => ToolResultMessage(
  toolCallId: id,
  toolName: 'read',
  content: [TextContent(text: 'result ${'r' * 300}')],
  isError: false,
  timestamp: DateTime.utc(2026),
);

String _markerText(UserMessage message) {
  final content = message.content;
  return content is String
      ? content
      : (content as List).whereType<TextContent>().map((c) => c.text).join();
}

void main() {
  group('localTrimValve (every in-memory valve site)', () {
    test('the trimmed context OPENS on the user-role marker and the newest '
        'user turn rides right behind it', () {
      final messages = <Message>[
        for (var i = 0; i < 20; i++) ...[
          UserMessage.text('question $i ${'q' * 400}'),
          _answer('answer $i ${'a' * 400}'),
        ],
        UserMessage.text('newest question ${'n' * 300}'),
      ];
      final trimmed = localTrimValve(
        messages: messages,
        reason: 'test valve',
        window: 3000,
        settings: const CompactionSettings(
          enabled: true,
          reserveTokens: 100,
          keepRecentTokens: 200,
        ),
        overheadTokens: 0,
      );
      expect(trimmed, isNotNull, reason: 'the fixture must trim');
      expect(trimmed!.dropped, greaterThan(0));
      expect(trimmed.messages.first, isA<UserMessage>());
      expect(
        _markerText(trimmed.messages.first as UserMessage),
        startsWith('[context trimmed locally:'),
      );
      final newest = messages.last;
      expect(
        trimmed.messages.skip(1).where((m) => identical(m, newest)),
        hasLength(1),
        reason: 'the newest user turn is carried verbatim (gh-2411)',
      );
    });
  });

  group('cutAtUserTurnBoundary', () {
    final leading = <Message>[
      _answer('orphaned answer'),
      _result('c1'),
      UserMessage.text('the question'),
      _answer('its answer'),
    ];

    test('cuts everything before the first user turn and reports it', () {
      final dropped = <(int, String)>[];
      final cut = cutAtUserTurnBoundary(
        leading,
        reason: 'over-window relief',
        onDropped: (count, site) => dropped.add((count, site)),
      );
      expect(cut.length, 2);
      expect(cut.first, isA<UserMessage>());
      expect(dropped, [(2, 'over-window relief')]);
    });

    test('a list that already opens on a user turn is returned as is', () {
      final already = leading.sublist(2);
      final cut = cutAtUserTurnBoundary(
        already,
        reason: 'site',
        onDropped: (count, _) => fail('nothing to drop ($count)'),
      );
      expect(identical(cut, already), isTrue);
      expect(cut.length, 2);
    });

    test(
      'a list without any user turn is left untouched (nothing invented)',
      () {
        final noUser = leading.sublist(0, 2);
        final cut = cutAtUserTurnBoundary(
          noUser,
          reason: 'site',
          onDropped: (count, _) => fail('nothing to drop ($count)'),
        );
        expect(identical(cut, noUser), isTrue);
        expect(
          cutAtUserTurnBoundary(
            const [],
            reason: 'site',
            onDropped: (count, _) => fail('nothing to drop ($count)'),
          ),
          isEmpty,
        );
      },
    );
  });

  group('gh-241 follow-up #5d (D4 — owner live test round 5)', () {
    test('a projection marker is machine content: the REAL newest user turn '
        'is carried behind the trim marker — never the hidden-record marker '
        'that follows it', () {
      final messages = <Message>[
        for (var i = 0; i < 20; i++) ...[
          UserMessage.text('question $i ${'q' * 400}'),
          _answer('answer $i ${'a' * 400}'),
        ],
        UserMessage.text('the REAL newest question nnn'),
        UserMessage.text('[175:hidden·tool_result·13k·"---"]'),
      ];
      final trimmed = localTrimValve(
        messages: messages,
        reason: 'test valve',
        window: 300,
        settings: const CompactionSettings(
          enabled: true,
          reserveTokens: 100,
          keepRecentTokens: 200,
        ),
        overheadTokens: 290,
      )!;
      final texts = trimmed.messages
          .whereType<UserMessage>()
          .map(_markerText)
          .toList();
      expect(
        texts,
        hasLength(3),
        reason: 'trim marker + the real turn + the hidden marker: $texts',
      );
      expect(texts[1], 'the REAL newest question nnn');
    });

    test('every projection marker form reads as synthetic: a (tagged) hidden '
        'or checkpoint marker, a bare or labelled expand pointer, the local '
        'trim marker — a tagged real question does not', () {
      const synthetic = [
        '[175:hidden·tool_result·13k·"---"]',
        'm5 [175:hidden·tool_result·13k·"---"]',
        '[3-140:ckpt·the early work]',
        '[expand 3-140]',
        'm7 [expand 12]',
        'old session list [expand 142-143]',
        '[context trimmed locally: test, 4 older message(s) were dropped]',
      ];
      for (final text in synthetic) {
        expect(isSyntheticUserText(text), isTrue, reason: text);
      }
      expect(
        isSyntheticUserText('m42 сколько будет 17 умножить на 23?'),
        isFalse,
      );
    });
  });
}
