// Agent Wire Protocol v1 server core (issue #1103) — TDD red first.
//
// UT-1:   single-attach gate + clean reattach.
// E1:     pending approval/ask/secret survives a detach and is re-delivered
//         to the next attach idempotently by request id.
// Dispatch: prompt/steer/abort/approval/ask/secret + loud errors.
import 'dart:async';

import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/tools/ask_tool.dart';
import 'package:flutter_agent_harness/src/tools/request_secret_tool.dart';
import 'package:flutter_agent_harness/src/wire/wire_protocol.dart';
import 'package:flutter_agent_harness/src/wire/wire_serve.dart';
import 'package:test/test.dart';

import 'golden_fixtures.dart';

/// Drives [WireServeServer] with in-memory closures — no agent, no network.
class _Harness {
  final sent = <Map<String, dynamic>>[];
  final logs = <String>[];
  final incoming = StreamController<Map<String, dynamic>>();
  final prompts = <String>[];
  final steers = <String>[];
  final decisions = <ApprovalDecision>[];
  final askAnswers = <List<AskAnswer>?>[];
  final secretResults = <RequestSecretResult?>[];
  var busy = false;
  var aborts = 0;
  bool failPrompt = false;
  bool withApproval = true;
  Completer<List<AskQuestion>?>? askGate;
  Completer<RequestSecretResult?>? secretGate;

  late final WireServeServer server;

  _Harness() {
    server = WireServeServer(
      runPrompt: (text) async {
        prompts.add(text);
        if (failPrompt) throw StateError('boom');
        // Emulates a tool call landing on the approval gate mid-run.
        if (withApproval) {
          decisions.add(
            await server.approvalPrompt(
              const ApprovalRequest(
                toolName: 'bash',
                tier: ApprovalTier.exec,
                arguments: {'command': 'rm -rf /tmp/x'},
                reason: 'critical pattern matched',
              ),
            ),
          );
        }
        if (askGate != null) {
          askAnswers.add(
            await server.answerAsk(const [
              AskQuestion(
                question: 'Deploy now?',
                options: [AskOption(label: 'yes')],
              ),
            ]),
          );
        }
        if (secretGate != null) {
          secretResults.add(
            await server.answerSecret('DEPLOY_TOKEN', 'needed to deploy'),
          );
        }
      },
      steer: steers.add,
      abort: () => aborts++,
      isBusy: () => busy,
      onLog: logs.add,
    );
  }

  /// A client speaking pure frames; [sent] collects every server frame.
  Future<void> attach() => server.attach(incoming.stream, sent.add);

  void clientSends(Map<String, dynamic> frame) => incoming.add(frame);

  /// A genuine transport fault (socket-reset analog), not a clean close.
  void clientError(Object error) => incoming.addError(error);

  Map<String, dynamic> kind(String kind) =>
      sent.firstWhere((f) => f['kind'] == kind, orElse: () => {});

  List<Map<String, dynamic>> allOf(String kind) =>
      sent.where((f) => f['kind'] == kind).toList();

  Future<void> close() async {
    await incoming.close();
  }
}

Map<String, dynamic> hello() => AgentWireProtocol().hello(versions: [1]);

void main() {
  tearDown(() async {});

  group('UT-1: single attach + reattach', () {
    test('handshake: hello is answered with a v1 welcome', () async {
      final h = _Harness();
      final served = h.attach();
      h.clientSends(hello());
      await _untilAttached(h);
      expect(h.kind('welcome')['v'], 1);
      expect(h.kind('welcome')['version'], 1);
      await h.close();
      await served;
    });

    test('second attach is rejected loudly with already_attached', () async {
      final h = _Harness();
      final served = h.attach();
      h.clientSends(hello());
      await _untilAttached(h);

      final secondSent = <Map<String, dynamic>>[];
      await h.server.attach(Stream.value(hello()), secondSent.add);
      expect(secondSent, hasLength(1));
      expect(secondSent.single['kind'], 'error');
      expect(secondSent.single['code'], 'already_attached');
      // The first client keeps working.
      h.server.handleAgentEvent(nativeEventFor('turn_start'));
      expect(h.kind('turn_start'), isNotEmpty);
      await h.close();
      await served;
    });

    test('after detach a new client attaches cleanly', () async {
      final h = _Harness();
      final served = h.attach();
      h.clientSends(hello());
      await _untilAttached(h);
      await h.close();
      await served;

      final thirdSent = <Map<String, dynamic>>[];
      final thirdIncoming = StreamController<Map<String, dynamic>>();
      final third = h.server.attach(thirdIncoming.stream, thirdSent.add);
      thirdIncoming.add(hello());
      await pump();
      expect(thirdSent.first['kind'], 'welcome');
      await thirdIncoming.close();
      await third;
    });

    test(
      'a transport FAULT detaches loudly and reattach still works',
      () async {
        final h = _Harness();
        final served = h.attach();
        h.clientSends(hello());
        await _untilAttached(h);
        // The detach below must be distinguishable from a clean hangup in
        // the diagnostics.
        h.clientError(StateError('socket reset'));
        await pump();
        await served;
        expect(
          h.logs.where((l) => l.contains('client detached: ')),
          isNotEmpty,
          reason: 'the fault must reach the diagnostics, not vanish',
        );

        // The server survives the fault and accepts a fresh client.
        final nextSent = <Map<String, dynamic>>[];
        final nextIncoming = StreamController<Map<String, dynamic>>();
        final next = h.server.attach(nextIncoming.stream, nextSent.add);
        nextIncoming.add(hello());
        await pump();
        expect(nextSent.first['kind'], 'welcome');
        await nextIncoming.close();
        await next;
      },
    );
  });

  group('command dispatch', () {
    test('prompt runs and the run streams encoded events', () async {
      final h = _Harness();
      final served = h.attach();
      h.clientSends(hello());
      await _untilAttached(h);

      h.clientSends(
        AgentWireProtocol().encodeCommand(const WirePromptCommand('hi')),
      );
      await pump();
      expect(h.prompts, ['hi']);
      h.server.handleAgentEvent(nativeEventFor('agent_start'));
      h.server.handleAgentEvent(nativeEventFor('turn_start'));
      expect(
        h.kind('turn_start'),
        loadGoldenFixtures(
          eventFixturesDir,
        ).firstWhere((f) => f.kind == 'turn_start').frame,
      );
      await h.close();
      await served;
    });

    test('prompt while busy is a loud busy error', () async {
      final h = _Harness()..busy = true;
      final served = h.attach();
      h.clientSends(hello());
      await _untilAttached(h);

      h.clientSends(
        AgentWireProtocol().encodeCommand(const WirePromptCommand('hi')),
      );
      await pump();
      final error = h.kind('error');
      expect(error['code'], 'busy');
      expect(h.prompts, isEmpty);
      await h.close();
      await served;
    });

    test('steer reaches the agent mid-run; abort aborts', () async {
      final h = _Harness()..busy = true;
      final served = h.attach();
      h.clientSends(hello());
      await _untilAttached(h);

      h.clientSends(
        AgentWireProtocol().encodeCommand(const WireSteerCommand('use git')),
      );
      h.clientSends(
        AgentWireProtocol().encodeCommand(const WireAbortCommand()),
      );
      await pump();
      expect(h.steers, ['use git']);
      expect(h.aborts, 1);
      await h.close();
      await served;
    });

    test('steer/abort while idle are loud not_running errors', () async {
      final h = _Harness();
      final served = h.attach();
      h.clientSends(hello());
      await _untilAttached(h);

      h.clientSends(
        AgentWireProtocol().encodeCommand(const WireSteerCommand('x')),
      );
      h.clientSends(
        AgentWireProtocol().encodeCommand(const WireAbortCommand()),
      );
      await pump();
      expect(h.allOf('error').map((e) => e['code']), [
        'not_running',
        'not_running',
      ]);
      expect(h.aborts, 0);
      await h.close();
      await served;
    });

    test(
      'unknown command and session_control are loud, run stays alive',
      () async {
        final h = _Harness();
        final served = h.attach();
        h.clientSends(hello());
        await _untilAttached(h);

        h.clientSends({'v': 1, 'kind': 'teleport', 'x': 1});
        h.clientSends(
          AgentWireProtocol().encodeCommand(
            const WireSessionControlCommand(op: 'ping'),
          ),
        );
        await pump();
        final codes = h.allOf('error').map((e) => e['code']).toList();
        expect(codes, contains('unknown_command'));
        expect(codes, contains('unsupported_session_control_op'));
        // The connection survives (E3 discipline).
        h.server.handleAgentEvent(nativeEventFor('turn_start'));
        expect(h.kind('turn_start'), isNotEmpty);
        await h.close();
        await served;
      },
    );

    test('malformed frame is a loud per-frame error, not a teardown', () async {
      final h = _Harness();
      final served = h.attach();
      h.clientSends(hello());
      await _untilAttached(h);

      h.clientSends({'v': 99, 'kind': 'prompt', 'text': 'x'});
      h.clientSends({'v': 1, 'kind': 'prompt'});
      await pump();
      expect(h.allOf('error').map((e) => e['code']), everyElement('bad_frame'));
      await h.close();
      await served;
    });

    test('runPrompt failure surfaces as run_failed, server stays up', () async {
      final h = _Harness()..failPrompt = true;
      final served = h.attach();
      h.clientSends(hello());
      await _untilAttached(h);

      h.clientSends(
        AgentWireProtocol().encodeCommand(const WirePromptCommand('hi')),
      );
      await pump();
      expect(h.kind('error')['code'], 'run_failed');
      expect(h.server.attached, isTrue);
      await h.close();
      await served;
    });
  });

  group('E1: host-interaction requests over the wire', () {
    test('approval round-trips by request id', () async {
      final h = _Harness();
      final served = h.attach();
      h.clientSends(hello());
      await _untilAttached(h);

      h.clientSends(
        AgentWireProtocol().encodeCommand(const WirePromptCommand('go')),
      );
      await pump();
      final request = h.kind('approval_request');
      expect(request['id'], isNotEmpty);
      expect(request['toolName'], 'bash');

      h.clientSends(
        AgentWireProtocol().encodeCommand(
          const WireApprovalResponseCommand(
            id: 'nonexistent',
            decision: ApprovalDecision.approveOnce,
          ),
        ),
      );
      await pump();
      expect(h.kind('error')['code'], 'unknown_request_id');

      h.clientSends(
        AgentWireProtocol().encodeCommand(
          WireApprovalResponseCommand(
            id: request['id'] as String,
            decision: ApprovalDecision.approveOnce,
          ),
        ),
      );
      await pump();
      expect(h.decisions, [ApprovalDecision.approveOnce]);

      // Idempotent by id: a late duplicate answer is a loud unknown id.
      h.clientSends(
        AgentWireProtocol().encodeCommand(
          WireApprovalResponseCommand(
            id: request['id'] as String,
            decision: ApprovalDecision.deny,
          ),
        ),
      );
      await pump();
      expect(h.decisions, hasLength(1));
      expect(h.allOf('error').last['code'], 'unknown_request_id');
      await h.close();
      await served;
    });

    test(
      'pending approval survives detach and is re-delivered to the next attach',
      () async {
        final h = _Harness();
        final served = h.attach();
        h.clientSends(hello());
        await _untilAttached(h);

        h.clientSends(
          AgentWireProtocol().encodeCommand(const WirePromptCommand('go')),
        );
        await pump();
        final firstDelivery = h.kind('approval_request');
        final requestId = firstDelivery['id'] as String;

        // Client dies mid-approval.
        await h.close();
        await served;

        final secondSent = <Map<String, dynamic>>[];
        final secondIncoming = StreamController<Map<String, dynamic>>();
        final second = h.server.attach(secondIncoming.stream, secondSent.add);
        secondIncoming.add(hello());
        await pump();
        // Re-delivered: same kind, same id, re-encoded for the new attach.
        final redelivered = secondSent.firstWhere(
          (f) => f['kind'] == 'approval_request',
          orElse: () => {},
        );
        expect(redelivered['id'], requestId);

        // The SAME id resolves the ORIGINAL waiter.
        secondIncoming.add(
          AgentWireProtocol().encodeCommand(
            WireApprovalResponseCommand(
              id: requestId,
              decision: ApprovalDecision.approveOnce,
            ),
          ),
        );
        await pump();
        expect(h.decisions, [ApprovalDecision.approveOnce]);
        await secondIncoming.close();
        await second;
      },
    );

    test('ask and secret round-trip; cancel maps to null', () async {
      final h = _Harness()..withApproval = false;
      final served = h.attach();
      h.clientSends(hello());
      await _untilAttached(h);

      // The scripted run asks, then requests a secret.
      h.askGate = Completer<List<AskQuestion>?>();
      h.secretGate = Completer<RequestSecretResult?>();
      h.clientSends(
        AgentWireProtocol().encodeCommand(const WirePromptCommand('deploy')),
      );
      await pump();
      final askFrame = h.kind('ask_request');
      expect(askFrame['id'], isNotEmpty);
      expect((askFrame['questions'] as List).first['question'], 'Deploy now?');

      h.clientSends(
        AgentWireProtocol().encodeCommand(
          WireAskResponseCommand(
            id: askFrame['id'] as String,
            answers: [
              const AskAnswer(selected: ['yes']),
            ],
          ),
        ),
      );
      await pump();
      // The answer reached the ask callback, and the secret request fired.
      final secretFrame = h.kind('secret_request');
      expect(secretFrame['id'], isNotEmpty);
      expect(secretFrame['name'], 'DEPLOY_TOKEN');

      h.clientSends(
        AgentWireProtocol().encodeCommand(
          const WireSecretResponseCommand(id: 'sec_mismatch'),
        ),
      );
      await pump();
      expect(h.allOf('error').last['code'], 'unknown_request_id');

      h.clientSends(
        AgentWireProtocol().encodeCommand(
          WireSecretResponseCommand(
            id: secretFrame['id'] as String,
            result: RequestSecretResult(
              name: 'DEPLOY_TOKEN',
              value: 'shh',
              persisted: false,
            ),
          ),
        ),
      );
      await pump();
      expect(h.askAnswers.single!.single.selected, ['yes']);
      expect(h.secretResults.single?.value, 'shh');
      await h.close();
      await served;
    });

    test('ask cancel maps to a null answer', () async {
      final h = _Harness()..withApproval = false;
      final served = h.attach();
      h.clientSends(hello());
      await _untilAttached(h);

      h.askGate = Completer<List<AskQuestion>?>();
      h.clientSends(
        AgentWireProtocol().encodeCommand(const WirePromptCommand('go')),
      );
      await pump();
      final askFrame = h.kind('ask_request');
      h.clientSends(
        AgentWireProtocol().encodeCommand(
          WireAskResponseCommand(id: askFrame['id'] as String),
        ),
      );
      await pump();
      expect(h.askAnswers.single, isNull);
      await h.close();
      await served;
    });
  });

  group('handshake and shutdown', () {
    test('non-hello first frame is a loud handshake failure', () async {
      final h = _Harness();
      final served = h.attach();
      h.clientSends({'v': 1, 'kind': 'prompt', 'text': 'x'});
      await pump();
      expect(h.kind('error')['code'], 'handshake_failed');
      await served; // attach already ended
      // Server is reusable.
      final sent2 = <Map<String, dynamic>>[];
      final in2 = StreamController<Map<String, dynamic>>();
      final served2 = h.server.attach(in2.stream, sent2.add);
      in2.add(hello());
      await pump();
      expect(sent2.first['kind'], 'welcome');
      await in2.close();
      await served2;
    });

    test('shutdown denies pending approvals and detaches', () async {
      final h = _Harness();
      final served = h.attach();
      h.clientSends(hello());
      await _untilAttached(h);

      h.clientSends(
        AgentWireProtocol().encodeCommand(const WirePromptCommand('go')),
      );
      await pump();
      expect(h.kind('approval_request'), isNotEmpty);

      await h.server.shutdown();
      await served;
      expect(h.decisions, [ApprovalDecision.deny]);
      expect(h.server.attached, isFalse);
    });

    test('no client: events are dropped without error', () async {
      final h = _Harness();
      h.server.handleAgentEvent(nativeEventFor('agent_start'));
      expect(h.sent, isEmpty);
    });
  });
  group('bad_frame (review #1113 r2, BLOCKING #1)', () {
    test('a malformed line emits a loud error frame pre-handshake', () {
      final h = _Harness();
      h.server.protocolError(
        'bad_frame',
        'FormatException: bad JSON',
        h.sent.add,
      );
      expect(h.sent, hasLength(1));
      final frame = h.sent.single;
      expect(frame['kind'], 'error');
      expect(frame['code'], 'bad_frame');
      expect(frame['message'], contains('bad JSON'));
      expect(frame['v'], wireProtocolVersion);
    });

    test('a malformed line post-handshake keeps the attach alive', () async {
      final h = _Harness();
      final incoming = StreamController<String>();
      final done = h.server.attach(
        incoming.stream
            .map((line) {
              try {
                return AgentWireProtocol.parseLine(line);
              } on FormatException catch (error) {
                h.server.protocolError('bad_frame', '$error', h.sent.add);
                return null;
              }
            })
            .where((f) => f != null)
            .cast<Map<String, dynamic>>(),
        h.sent.add,
      );
      incoming.add('not json');
      await pump();
      expect(h.sent.map((f) => f['code']), contains('bad_frame'));
      // Still attached: a valid hello after the bad line completes fine.
      incoming.add('{"v":1,"kind":"hello","versions":[1]}');
      await _untilAttached(h);
      expect(h.server.attached, isTrue);
      await incoming.close();
      await done;
    });

    test(
      'a request after shutdown resolves to the safe refusal immediately',
      () async {
        final h = _Harness();
        await h.server.shutdown();
        final sw = Stopwatch()..start();
        final decision = await h.server.approvalPrompt(
          const ApprovalRequest(
            toolName: 'bash',
            tier: ApprovalTier.exec,
            arguments: {'command': 'rm -rf /tmp/x'},
            reason: 'critical pattern matched',
          ),
        );
        expect(decision, ApprovalDecision.deny);
        expect(
          sw.elapsedMilliseconds,
          lessThan(1000),
          reason: 'no settle-window wedge after shutdown (review r3)',
        );
        expect(
          await h.server.answerAsk(const [
            AskQuestion(
              question: 'Deploy now?',
              options: [AskOption(label: 'yes')],
            ),
          ]),
          isNull,
        );
        expect(await h.server.answerSecret('k', 'why'), isNull);
      },
    );
  });
}

/// Waits until the client finished the handshake.
Future<void> _untilAttached(_Harness h) async {
  for (var i = 0; i < 1000; i++) {
    if (h.server.attached) return;
    await pump();
  }
  fail('client never attached');
}

/// Drives a full attach + hello, then hands the server [line] as a raw
/// NDJSON line through [decodeLine] (the bin host's decode step) and
/// returns what came back out.

Future<void> pump() => Future<void>.delayed(Duration.zero);
