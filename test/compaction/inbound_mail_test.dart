// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// PR #2435 addendum — unanswered inbound inter-agent mail is never a
/// mechanical compaction candidate.
///
/// The live clip that pinned it: a peer's mail delivered into a busy
/// agent's session, the autonomous chain paused on its budget with one
/// message queued — while every context-bounding tier could fold an
/// earlier delivered-but-unanswered mail away MECHANICALLY. The
/// prompt-level belt (`## Open User Requests`, issue #81 v2) is
/// judgment-only (AC9: "the summarizer LLM judges openness"), and the
/// ledger's exempt tag classifies only the DM delivery shape
/// (`from <id>: …`) as synthetic — the channel shape
/// (`from <id> in #<channel>: …`, the DAP delivery the ai_kb session
/// actually carries) is neither exempt nor otherwise protected.
///
/// The invariant: an inbound mail record with NO later assistant record
/// is open data — never a judge hide pick, never a relief hide
/// candidate, never dropped by the local trim valve. Once a later
/// assistant record exists the mail folds like any other data.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/agent/auto_compactor.dart'
    show localTrimValve;
import 'package:flutter_agent_harness/src/compaction/structured/judge.dart'
    show validateHidePicks;
import 'package:flutter_agent_harness/src/compaction/structured/ledger.dart'
    show buildContextLedger;
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart'
    show RecordSeqIndex;
import 'package:test/test.dart';

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) {
  return AssistantMessage(
    content: [
      TextContent(text: text),
      ...?calls,
    ],
    api: 'anthropic-messages',
    provider: 'p',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

ToolResultMessage _result(
  String callId,
  String name,
  String text, {
  bool isError = false,
}) {
  return ToolResultMessage(
    toolCallId: callId,
    toolName: name,
    content: [TextContent(text: text)],
    isError: isError,
    timestamp: DateTime.utc(2026),
  );
}

/// Window 8000, reserve 2000 → trigger/relief target 6000; keep-recent
/// 2000 (the trim valve's kept region).
const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 2000,
  keepRecentTokens: 2000,
);

AgentState _state(List<Message> messages) => AgentState(
  model: Model(
    id: 'm1',
    name: 'm1',
    api: 'anthropic-messages',
    provider: 'p',
    baseUrl: 'http://localhost:1',
    contextWindow: 8000,
    maxTokens: 4096,
  ),
  messages: messages,
);

/// One read pair: an assistant carrier with a `read` call plus its
/// result ([chars] payload chars ≈ chars/4 tokens).
List<Message> _readPair(
  String callId,
  String path,
  String payloadChar, {
  int chars = 8000,
}) => [
  _assistant(
    'reading $path',
    calls: [
      ToolCall(id: callId, name: 'read', arguments: {'path': path}),
    ],
  ),
  _result(callId, 'read', payloadChar * chars),
];

const _dmMail = 'from 01a0d73f-8d78-7dd2-9a2e-a6b606777217/main: ping';
const _channelMail =
    'from 3cfaee1aa054fe6e in #cd65d0de4c: roll-call\n'
    '[reply into this channel with agent_message to: "#cd65d0de4c"]';

SessionRecord _record(Message message, int n) => MessageRecord(
  id: 'r$n',
  parentId: n == 1 ? null : 'r${n - 1}',
  timestamp: DateTime.utc(2026),
  message: message,
);

void main() {
  group('isAgentMailText', () {
    test('the DM delivery shape', () {
      expect(isAgentMailText(_dmMail), isTrue);
    });

    test('the channel delivery shape with the reply anchor', () {
      expect(isAgentMailText(_channelMail), isTrue);
    });

    test('the anchor alone (multi-line bodies, trailing envelope)', () {
      expect(
        isAgentMailText(
          'some forwarded body text\n'
          '[reply into this channel with agent_message to: "#c"]',
        ),
        isTrue,
      );
    });

    test('the user\'s own words are never mail', () {
      expect(isAgentMailText('fix the login crash'), isFalse);
      expect(isAgentMailText(''), isFalse);
    });

    test(
      'the attach-view form is the user\'s own words (user_text doctrine)',
      () {
        expect(isAgentMailText('[from agent-x] please look at this'), isFalse);
      },
    );
  });

  group('unansweredInboundMailRecordIds', () {
    test('a mail with no later assistant record is open', () {
      final records = [
        _record(UserMessage.text('inspect the config'), 1),
        _record(UserMessage.text(_channelMail), 2),
      ];
      expect(unansweredInboundMailRecordIds(records), {'r2'});
    });

    test('a mail followed by an assistant record folds like data', () {
      final records = [
        _record(UserMessage.text(_dmMail), 1),
        _record(_assistant('on it'), 2),
        _record(UserMessage.text(_channelMail), 3),
      ];
      expect(unansweredInboundMailRecordIds(records), {'r3'});
    });

    test('all mail is open when the session has no assistant record', () {
      final records = [
        _record(UserMessage.text(_dmMail), 1),
        _record(UserMessage.text(_channelMail), 2),
        _record(UserMessage.text('real user turn'), 3),
      ];
      expect(unansweredInboundMailRecordIds(records), {'r1', 'r2'});
    });

    test('tool-call carriers and results never count as a reply', () {
      final records = [
        _record(UserMessage.text(_channelMail), 1),
        _record(
          _assistant(
            'reading',
            calls: [ToolCall(id: 'c1', name: 'read', arguments: {})],
          ),
          2,
        ),
        _record(_result('c1', 'read', 'out'), 3),
        _record(UserMessage.text('<system-notice>job done</system-notice>'), 4),
      ];
      // An assistant carrier with an ordinary tool call is the agent
      // WORKING after the mail, not answering it — the mail stays open.
      expect(unansweredInboundMailRecordIds(records), {'r1'});
    });

    test('an agent_message tool call or pure prose closes the mail', () {
      final records = [
        _record(UserMessage.text(_channelMail), 1),
        _record(
          _assistant(
            'replying',
            calls: [ToolCall(id: 'c1', name: 'agent_message', arguments: {})],
          ),
          2,
        ),
      ];
      expect(unansweredInboundMailRecordIds(records), isEmpty);

      final prose = [
        _record(UserMessage.text(_dmMail), 1),
        _record(_assistant('here is the answer, colleague'), 2),
      ];
      expect(unansweredInboundMailRecordIds(prose), isEmpty);
    });

    test('an empty path protects nothing', () {
      expect(unansweredInboundMailRecordIds(const []), isEmpty);
    });
  });

  group('unansweredAgentMailMessageIndices', () {
    test('mirrors the record-level view over live messages', () {
      final messages = <Message>[
        UserMessage.text(_dmMail),
        _assistant('on it'),
        UserMessage.text(_channelMail),
        _result('c1', 'read', 'out'),
      ];
      expect(unansweredAgentMailMessageIndices(messages), [2]);
    });
  });

  group('validateHidePicks and the mail', () {
    test('user-role records are already exempt — the belt is pinned', () {
      final records = <SessionRecord>[
        _record(UserMessage.text(_channelMail), 1),
        _record(_assistant('filler'), 2),
        _record(UserMessage.text('real ask'), 3),
      ];
      final ledger = buildContextLedger(
        visiblePath: records,
        seqs: RecordSeqIndex(records),
      );

      // The judge layer refuses EVERY user-role record (ledger exempt:
      // `kind == 'user'`, F8/F9) — delivered mail was never
      // judge-hideable. Pinned here as a regression guard: the pins
      // merge below is defense-in-depth, not the primary belt.
      final bare = validateHidePicks({1}, ledger, protectLastN: 0);
      expect(bare, isEmpty);

      final ids = validateHidePicks(
        {1},
        ledger,
        protectLastN: 0,
        pinnedRecordIds: unansweredInboundMailRecordIds(records),
      );
      expect(ids, isEmpty);
    });
  });

  group('localTrimValve carries unanswered mail', () {
    test('an unanswered mail behind the cut re-homes after the marker', () {
      final messages = <Message>[
        UserMessage.text(_channelMail), // unanswered — behind the cut
        ..._readPair('c1', 'a.dart', 'a', chars: 4000),
        ..._readPair('c2', 'b.dart', 'b', chars: 4000),
        ..._readPair('c3', 'c.dart', 'c', chars: 4000),
      ];

      final trimmed = localTrimValve(
        messages: messages,
        reason: 'test',
        window: 8000,
        settings: _settings,
        overheadTokens: 0,
      );

      expect(trimmed, isNotNull);
      final texts = trimmed!.messages
          .whereType<UserMessage>()
          .map((m) => (m.content as String))
          .toList();
      expect(
        texts.any((t) => t.contains('roll-call')),
        isTrue,
        reason: 'the unanswered mail must survive the valve',
      );
    });

    test('an answered mail folds like data', () {
      final messages = <Message>[
        UserMessage.text(_dmMail), // answered by the agent_message below
        _assistant(
          'on it',
          calls: [ToolCall(id: 'c0', name: 'agent_message', arguments: {})],
        ),
        ..._readPair('c1', 'a.dart', 'a', chars: 4000),
        ..._readPair('c2', 'b.dart', 'b', chars: 4000),
        ..._readPair('c3', 'c.dart', 'c', chars: 4000),
      ];

      final trimmed = localTrimValve(
        messages: messages,
        reason: 'test',
        window: 8000,
        settings: _settings,
        overheadTokens: 0,
      );

      expect(trimmed, isNotNull);
      final texts = trimmed!.messages
          .whereType<UserMessage>()
          .map((m) => (m.content as String))
          .toList();
      expect(texts.any((t) => t.contains('from 01a0d73f')), isFalse);
    });
  });

  group('emergency relief keeps unanswered mail', () {
    late MemoryFileSystem fs;
    late JsonlSessionRepo repo;

    setUp(() {
      fs = MemoryFileSystem();
      repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
    });

    test('the valve bounds the context and the mail survives', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text(_channelMail));
      for (final pair in [
        // Twenty-two pairs at ~309 tokens each: ~6.8k tokens in — over
        // the relief target (window 8000 - reserve 2000 = 6000) — while
        // the newest result (300) stays inside the valve's keep budget
        // (400), so its kept region is non-empty and the carried-mail
        // path (the belt under test) actually runs.
        ..._readPair('r1', 'a01.dart', '`', chars: 1200),
        ..._readPair('r2', 'a02.dart', 'a', chars: 1200),
        ..._readPair('r3', 'a03.dart', 'b', chars: 1200),
        ..._readPair('r4', 'a04.dart', 'c', chars: 1200),
        ..._readPair('r5', 'a05.dart', 'd', chars: 1200),
        ..._readPair('r6', 'a06.dart', 'e', chars: 1200),
        ..._readPair('r7', 'a07.dart', 'f', chars: 1200),
        ..._readPair('r8', 'a08.dart', 'g', chars: 1200),
        ..._readPair('r9', 'a09.dart', 'h', chars: 1200),
        ..._readPair('r10', 'a10.dart', 'i', chars: 1200),
        ..._readPair('r11', 'a11.dart', 'j', chars: 1200),
        ..._readPair('r12', 'a12.dart', 'k', chars: 1200),
        ..._readPair('r13', 'a13.dart', 'l', chars: 1200),
        ..._readPair('r14', 'a14.dart', 'm', chars: 1200),
        ..._readPair('r15', 'a15.dart', 'n', chars: 1200),
        ..._readPair('r16', 'a16.dart', 'o', chars: 1200),
        ..._readPair('r17', 'a17.dart', 'p', chars: 1200),
        ..._readPair('r18', 'a18.dart', 'q', chars: 1200),
        ..._readPair('r19', 'a19.dart', 'r', chars: 1200),
        ..._readPair('r20', 'a20.dart', 's', chars: 1200),
        ..._readPair('r21', 'a21.dart', 't', chars: 1200),
        ..._readPair('r22', 'a22.dart', 'u', chars: 1200),
      ]) {
        await session.appendMessage(pair);
      }
      final state = _state(await session.buildContextMessages());
      // keepRecent (400) below the relief target (8000-2000=600): the
      // transcript (~1255 tokens) exceeds the keep-recent floor, so the
      // valve actually cuts — and its kept region can land under the
      // target. The valve's carried-mail path is the belt under test.
      final relief = EmergencyRelief(
        session: session,
        state: state,
        window: 8000,
        settings: const CompactionSettings(
          enabled: true,
          reserveTokens: 2000,
          keepRecentTokens: 400,
        ),
        keepRecent: const {'read': 99, 'exec': 99, 'other': 99},
        protectLastN: 2,
      );

      final outcome = await relief.run();

      expect(outcome.usedTrimValve, isTrue);
      expect(outcome.droppedMessages, greaterThanOrEqualTo(1));
      final texts = state.messages
          .whereType<UserMessage>()
          .map((m) => (m.content as String))
          .toList();
      expect(
        texts.any((t) => t.contains('roll-call')),
        isTrue,
        reason: 'the unanswered mail must survive the mechanical tier',
      );
    });
  });
}
