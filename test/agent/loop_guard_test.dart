import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// gh-2461 — the identical-call loop guard: streak detection, notice and
/// abort behavior, and the false-positive budget the acceptance names:
/// legitimately repeated calls with DIFFERENT args, intentional polling
/// (per-call-site opt-out), and user/steering interruptions all stay
/// un-tripped.
void main() {
  const model = Model(
    id: 'test-model',
    api: 'test-api',
    provider: 'test-provider',
    baseUrl: 'https://example.test',
    contextWindow: 100000,
    maxTokens: 4096,
  );

  AssistantMessage assistant({
    List<ContentBlock> content = const [],
    StopReason stopReason = StopReason.stop,
  }) => AssistantMessage(
    content: content,
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );

  ToolCall read(Map<String, dynamic> args, {String id = 'c'}) =>
      ToolCall(id: id, name: 'read', arguments: args);

  List<AssistantMessageEvent> toolTurn(ToolCall call) => [
    StartEvent(partial: assistant()),
    ToolCallStartEvent(contentIndex: 0, partial: assistant()),
    ToolCallEndEvent(
      contentIndex: 0,
      toolCall: call,
      partial: assistant(content: [call]),
    ),
    DoneEvent(
      reason: StopReason.toolUse,
      message: assistant(content: [call], stopReason: StopReason.toolUse),
    ),
  ];

  List<AssistantMessageEvent> textTurn(String text) => [
    StartEvent(partial: assistant()),
    TextStartEvent(contentIndex: 0, partial: assistant()),
    TextDeltaEvent(
      contentIndex: 0,
      delta: text,
      partial: assistant(content: [TextContent(text: text)]),
    ),
    DoneEvent(
      reason: StopReason.stop,
      message: assistant(content: [TextContent(text: text)]),
    ),
  ];

  group('unit: key normalization', () {
    test('argument key order does not change the call identity', () {
      expect(
        normalizedToolCallArgsJson({'a': 1, 'b': 2}),
        normalizedToolCallArgsJson({'b': 2, 'a': 1}),
      );
    });

    test('nested containers normalize recursively', () {
      expect(
        normalizedToolCallArgsJson({
          'outer': {
            'y': [3, 4],
            'x': 1,
          },
        }),
        normalizedToolCallArgsJson({
          'outer': {
            'x': 1,
            'y': [3, 4],
          },
        }),
      );
    });

    test('different arguments are a different call', () {
      expect(
        normalizedToolCallArgsJson({'path': '/a.js'}),
        isNot(normalizedToolCallArgsJson({'path': '/b.js'})),
      );
    });

    test('unserializable arg leaves degrade to a stable string form — '
        'the guard never wedges the run (the unserializable-args fixture '
        'shape, gh-1931 sibling)', () {
      final weird = Object();
      final key = normalizedToolCallArgsJson({'weird': weird});
      expect(key, isA<String>());
      expect(key, contains(weird.toString()));
      // Stable: the same leaf normalizes identically.
      expect(
        normalizedToolCallArgsJson({'weird': weird}),
        normalizedToolCallArgsJson({'weird': weird}),
      );
      // And the full turn key builds without throwing.
      expect(
        identicalCallTurnKey(
          assistant(
            content: [
              read({'weird': weird}, id: 'u1'),
            ],
          ),
        ),
        isNotNull,
      );
    });

    test('a tool-free assistant turn has no loop identity (reset)', () {
      expect(identicalCallTurnKey(assistant()), isNull);
      expect(
        identicalCallTurnKey(assistant(content: [TextContent(text: 'hi')])),
        isNull,
      );
    });

    test('identical calls share the key regardless of provider call id', () {
      final key1 = identicalCallTurnKey(
        assistant(
          content: [
            read({'path': '/x'}, id: 'call-1'),
          ],
        ),
      );
      final key2 = identicalCallTurnKey(
        assistant(
          content: [
            read({'path': '/x'}, id: 'call-999'),
          ],
        ),
      );
      expect(key1, key2);
    });
  });

  group('unit: threshold contract', () {
    test('a non-positive noticeThreshold cannot construct the guard — '
        'the documented ≤ 0 disable is enforced at construction', () {
      // The doc says "[noticeThreshold] ≤ 0 disables the whole guard";
      // a negative threshold passing the old `!= 0` assert would arm the
      // notice on the FIRST turn of every streak in a release build
      // (`1 >= -1`) — the exact opposite of the documented disable.
      expect(
        () => IdenticalCallLoopGuard(noticeThreshold: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => IdenticalCallLoopGuard(noticeThreshold: -1),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('loop: streak detection', () {
    /// Drives a scripted run of [turns] and returns the run artifacts.
    Future<
      ({
        List<ToolCall> executed,
        List<List<String>> requestRoles,
        List<String?> lastUserTextAtRequest,
        List<Message> transcript,
      })
    >
    drive(
      List<List<AssistantMessageEvent>> turns, {
      AgentLoopConfig config = const AgentLoopConfig(model: model),
    }) async {
      final requestRoles = <List<String>>[];
      final lastUserTextAtRequest = <String?>[];
      var served = 0;
      AssistantMessageEventStream fakeCall(
        Model _,
        Context context, {
        CancelToken? cancelToken,
      }) {
        // Snapshot: the loop MUTATES the handed-out context.
        requestRoles.add([for (final m in context.messages) m.role]);
        final last = context.messages.lastOrNull;
        lastUserTextAtRequest.add(
          last is UserMessage ? userMessageText(last.content) : null,
        );
        final out = AssistantMessageEventStream();
        final turn = turns[served.clamp(0, turns.length - 1)];
        served++;
        unawaited(
          Future(() async {
            for (final event in turn) {
              out.push(event);
            }
            out.end();
          }),
        );
        return out;
      }

      final executed = <ToolCall>[];
      final stream = agentLoop(
        prompts: [UserMessage.text('go')],
        context: Context(
          messages: [],
          tools: [
            const Tool(name: 'read', description: 'read', parameters: {}),
            const Tool(name: 'watch', description: 'watch', parameters: {}),
          ],
        ),
        config: config,
        streamFunction: fakeCall,
        toolExecutor: (toolCall, cancelToken, _) async {
          executed.add(toolCall);
          return ToolExecutionResult.text('result');
        },
      );
      await stream.toList();
      return (
        executed: executed,
        requestRoles: requestRoles,
        lastUserTextAtRequest: lastUserTextAtRequest,
        transcript: await stream.result,
      );
    }

    List<List<AssistantMessageEvent>> identicalReads(
      int count, {
      String path = '/tmp/wt/js/sm/verdictAndFailState.js',
    }) => [
      for (var i = 0; i < count; i++)
        toolTurn(read({'path': path}, id: 'call-$i')),
    ];

    test('notice at 5 identical turns, honest abort at 8', () async {
      final run = await drive([
        ...identicalReads(8),
        // Unreachable — the abort ends the run after the 8th identical
        // exchange; the 9th provider call never happens.
        textTurn('done'),
      ]);

      // All 8 identical exchanges executed (the verdict is outcome-aware
      // and lands after the phase); the 9th provider call never happens —
      // the script's text turn is unreachable.
      expect(run.executed, hasLength(8));
      expect(run.requestRoles, hasLength(8));

      // The notice rode the request for turn 6 as the tail user message.
      expect(run.lastUserTextAtRequest[5], contains('loop guard'));
      expect(run.lastUserTextAtRequest[5], contains('system-notice'));
      expect(run.lastUserTextAtRequest[5], contains('re-plan'));
      // The turn-5 request (index 4) was still notice-free.
      expect(run.lastUserTextAtRequest[4], isNull);

      // The run ended on an honest error terminal naming the guard.
      final last = run.transcript.last as AssistantMessage;
      expect(last.stopReason, StopReason.error);
      expect(last.errorMessage, contains('identical tool-call loop guard'));
      expect(last.errorMessage, contains('8 times'));
      expect(last.errorMessage, contains('identicalCallExemptTools'));

      // The transcript keeps the truth: 8 result pairs + the notice +
      // the stop terminal.
      expect(run.transcript.map((m) => m.role).toList(), [
        'user', // prompt
        'assistant', 'toolResult', // 1
        'assistant', 'toolResult', // 2
        'assistant', 'toolResult', // 3
        'assistant', 'toolResult', // 4
        'assistant', 'toolResult', // 5
        'user', // the loop-guard notice
        'assistant', 'toolResult', // 6
        'assistant', 'toolResult', // 7
        'assistant', 'toolResult', // 8
        'assistant', // the stop terminal
      ]);
    });

    test(
      'legitimately repeated calls with DIFFERENT args never trip',
      () async {
        final turns = <List<AssistantMessageEvent>>[
          for (var i = 0; i < 20; i++)
            toolTurn(read({'path': '/f$i.js'}, id: 'call-$i')),
          textTurn('done'),
        ];
        final run = await drive(turns);
        expect(run.executed, hasLength(20));
        final last = run.transcript.last as AssistantMessage;
        expect(last.stopReason, StopReason.stop);
        for (final text in run.lastUserTextAtRequest) {
          if (text != null) expect(text, isNot(contains('loop guard')));
        }
      },
    );

    test('an interleaved different call keeps resetting the streak', () async {
      final turns = <List<AssistantMessageEvent>>[];
      for (var i = 0; i < 5; i++) {
        turns
          ..add(toolTurn(read({'path': '/same.js'}, id: 'a-$i')))
          ..add(toolTurn(read({'path': '/other$i.js'}, id: 'b-$i')));
      }
      turns.add(textTurn('done'));
      final run = await drive(turns);
      expect(run.executed, hasLength(10));
      final last = run.transcript.last as AssistantMessage;
      expect(last.stopReason, StopReason.stop);
    });

    test('a tool-free turn resets the streak (unit: a text answer ends a '
        'run, so the reset is pinned on the guard directly)', () {
      final guard = IdenticalCallLoopGuard();
      for (var i = 0; i < 4; i++) {
        final verdict = guard.acceptTurn(
          assistant(
            content: [
              read({'path': '/x'}, id: 'c$i'),
            ],
          ),
        );
        expect(verdict.action, IdenticalCallAction.none);
      }
      // A tool-free turn carries no loop identity — the streak resets.
      expect(
        guard.acceptTurn(assistant(content: [TextContent(text: 'hi')])).action,
        IdenticalCallAction.none,
      );
      expect(guard.streak, 0);
      for (var i = 0; i < 4; i++) {
        guard.acceptTurn(
          assistant(
            content: [
              read({'path': '/x'}, id: 'd$i'),
            ],
          ),
        );
      }
      // 4 identical after the reset — still below the notice threshold.
      expect(guard.streak, 4);
      final verdict = guard.acceptTurn(
        assistant(
          content: [
            read({'path': '/x'}, id: 'd5'),
          ],
        ),
      );
      expect(verdict.action, IdenticalCallAction.injectNotice);
    });

    test('an all-failing turn is the breaker\u0027s domain — the streak does '
        'not advance (issue #862 separation)', () {
      final guard = IdenticalCallLoopGuard();
      for (var i = 0; i < 6; i++) {
        final verdict = guard.acceptTurn(
          assistant(
            content: [
              read({'path': '/x'}, id: 'e$i'),
            ],
          ),
          turnSucceeded: false,
        );
        expect(verdict.action, IdenticalCallAction.none);
        expect(guard.streak, 0);
      }
      // A succeeding identical exchange advances normally afterwards.
      guard.acceptTurn(
        assistant(
          content: [
            read({'path': '/x'}, id: 's1'),
          ],
        ),
      );
      expect(guard.streak, 1);
    });

    test(
      'exempt tool calls are opted out per call site (watch/polling)',
      () async {
        final turns = [
          for (var i = 0; i < 10; i++)
            toolTurn(
              ToolCall(id: 'w-$i', name: 'watch', arguments: {'job': 'j1'}),
            ),
          textTurn('done'),
        ];
        final run = await drive(
          turns,
          config: const AgentLoopConfig(
            model: model,
            identicalCallExemptTools: {'watch'},
          ),
        );
        expect(run.executed, hasLength(10));
        final last = run.transcript.last as AssistantMessage;
        expect(last.stopReason, StopReason.stop);
      },
    );

    test('a user steering message between identical turns resets', () async {
      var polls = 0;
      final turns = [
        ...identicalReads(4),
        ...identicalReads(4),
        textTurn('done'),
      ];
      final run = await drive(
        turns,
        config: AgentLoopConfig(
          model: model,
          getSteeringMessages: () async {
            // Poll #1 is the pre-loop check; #2..#5 are the per-turn
            // boundary polls. The steering message lands at the boundary
            // AFTER the 4th identical turn (the 5th poll).
            final n = polls++;
            return n == 4
                ? [UserMessage.text('check the logs first please')]
                : const <Message>[];
          },
        ),
      );
      expect(run.executed, hasLength(8));
      final last = run.transcript.last as AssistantMessage;
      expect(last.stopReason, StopReason.stop);
      // The steering message really rode a request.
      expect(
        run.lastUserTextAtRequest.any(
          (t) => t?.contains('check the logs') ?? false,
        ),
        isTrue,
      );
    });

    test('a queued context notice does NOT reset the streak — machine '
        'notices are not steering evidence', () async {
      // gh-2423 pending context notices (near-limit compaction notices,
      // post-hide child records) ride the injection slot right before the
      // assistant turn; a degenerate read loop growing its context is
      // exactly where they fire. They are machine content, NOT the
      // user/steering evidence the reset contract names — the streak must
      // survive them, or each queued notice buys the loop 5 fresh
      // identical calls.
      var noticePolls = 0;
      final turns = [...identicalReads(9), textTurn('done')];
      final run = await drive(
        turns,
        config: AgentLoopConfig(
          model: model,
          takePendingNotices: () {
            // One notice queued at the turn-5 boundary (mid-streak: 4
            // identical exchanges already stand).
            return noticePolls++ == 4
                ? [
                    UserMessage.text(
                      '<system-notice>near context limit — compacting '
                      'hidden turns</system-notice>',
                    ),
                  ]
                : const <Message>[];
          },
        ),
      );
      // The streak survived the notice: the honest abort lands on the 8th
      // identical exchange and the scripted tail never runs. (With the
      // reset bug the notice restarts the count and the loop walks all 9
      // scripted reads plus the text turn to a clean stop.)
      expect(run.executed, hasLength(8));
      final last = run.transcript.last as AssistantMessage;
      expect(last.stopReason, StopReason.error);
      expect(last.errorMessage, contains('identical tool-call loop guard'));
      // The notice really rode a request (it was delivered — it just
      // never reset the streak).
      expect(
        run.lastUserTextAtRequest.any(
          (t) => t?.contains('near context limit') ?? false,
        ),
        isTrue,
      );
    });

    test('the guard is fully disabled with noticeThreshold 0', () async {
      final turns = [...identicalReads(12), textTurn('done')];
      final run = await drive(
        turns,
        config: const AgentLoopConfig(
          model: model,
          identicalCallNoticeThreshold: 0,
        ),
      );
      expect(run.executed, hasLength(12));
      final last = run.transcript.last as AssistantMessage;
      expect(last.stopReason, StopReason.stop);
    });

    test('abortThreshold 0 keeps the run alive past the notice', () async {
      final turns = [...identicalReads(12), textTurn('done')];
      final run = await drive(
        turns,
        config: const AgentLoopConfig(
          model: model,
          identicalCallAbortThreshold: 0,
        ),
      );
      expect(run.executed, hasLength(12));
      // The notice still fired — once.
      final noticeRequests = run.lastUserTextAtRequest
          .where((t) => t?.contains('loop guard') ?? false)
          .length;
      expect(noticeRequests, 1);
      final last = run.transcript.last as AssistantMessage;
      expect(last.stopReason, StopReason.stop);
    });

    test(
      'a mixed turn (same call + another) is a DIFFERENT identity',
      () async {
        final mixed = <List<AssistantMessageEvent>>[];
        for (var i = 0; i < 6; i++) {
          mixed.add([
            StartEvent(partial: assistant()),
            for (var j = 0; j < 2; j++) ...[
              ToolCallStartEvent(contentIndex: j, partial: assistant()),
              ToolCallEndEvent(
                contentIndex: j,
                toolCall: j == 0
                    ? read({'path': '/same.js'}, id: 'm-$i-a')
                    : read({'path': '/v$i.js'}, id: 'm-$i-b'),
                partial: assistant(
                  content: [
                    read({'path': '/same.js'}, id: 'm-$i-a'),
                    read({'path': '/v$i.js'}, id: 'm-$i-b'),
                  ],
                ),
              ),
            ],
            DoneEvent(
              reason: StopReason.toolUse,
              message: assistant(
                content: [
                  read({'path': '/same.js'}, id: 'm-$i-a'),
                  read({'path': '/v$i.js'}, id: 'm-$i-b'),
                ],
                stopReason: StopReason.toolUse,
              ),
            ),
          ]);
        }
        mixed.add(textTurn('done'));
        final run = await drive(mixed);
        expect(run.executed, hasLength(12));
        final last = run.transcript.last as AssistantMessage;
        expect(last.stopReason, StopReason.stop);
      },
    );
  });
}
