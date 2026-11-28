import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// gh-2470 end-to-end: a poisoned endpoint that refuses every LARGE
/// request with `finish_reason: error` — deterministically, on a history
/// the lying catalog window claims is fine — must (a) spend only the
/// configured retries, (b) surface the probable-overflow classification,
/// (c) trigger the compaction relief, and (d) never re-send the
/// byte-identical poisonous history on the continuation: the funnel's
/// continuation rides the COMPACTED transcript.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  late Future<bool> Function(Duration, CancelToken?) savedSleeper;
  late TransientRetryNotice? savedNotice;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    savedSleeper = transientRetrySleeper;
    savedNotice = transientRetryNotice;
    // The ladder's inter-attempt sleeps must not slow the test.
    transientRetrySleeper = (delay, token) async => true;
    transientRetryNotice = null;
    // The poison payload: a real `read` tool result (~48k chars ≈ 12k
    // estimated tokens) — the same fixture shape as the over-window
    // funnel tests, but the refusal here comes from the ENDPOINT (the
    // fake), not the loop's guard.
    env.writeFile('big.txt', List.filled(1080, 'x' * 45).join('\n'));
  });

  tearDown(() {
    transientRetrySleeper = savedSleeper;
    transientRetryNotice = savedNotice;
    io.close();
  });

  /// The refusal threshold, in the estimator's coarse chars/4 terms:
  /// request 1 (prompt + tools ≈ 3.4k estimated tokens) passes, request 2
  /// (transcript + the ~12k-token read result) is refused — exactly the
  /// ticket's shape (a history that succeeded minutes earlier now fails
  /// deterministically).
  const poisonTokensOver = 800 * 4;

  /// The poisoned endpoint: refuses any request over the threshold with
  /// the ticket's exact failure, serves the scripted turns otherwise.
  /// Every call is recorded for the byte-identical-retry assertion.
  final poisoned = PoisonedStream(
    refusalOverChars: poisonTokensOver,
    turns: [
      toolTurn([
        const ToolCall(id: 't1', name: 'read', arguments: {'path': 'big.txt'}),
      ]),
      textTurn('task complete after the compaction'),
      textTurn('no durable facts — nothing worth remembering'),
    ],
  );

  /// The healthy smol-role summarizer: compaction must NOT ride the
  /// poisoned endpoint (a summarizer request carries the history and
  /// would be refused for the same reason).
  final smol = FakeStreamFunction([
    textTurn('summary of the compacted history'),
    textTurn('summary of the compacted history'),
    textTurn('summary of the compacted history'),
  ]);

  test(
    'a probable-overflow stop auto-compacts and continues on the compacted '
    'history — the poisonous payload never re-sends',
    timeout: const Timeout(Duration(seconds: 180)),
    () async {
      final cli = AgentCli(
        config: AgentCliConfig(
          systemPrompt: tinyPrompt,
          // The forensics fa.log rides the home dir — the guard-class
          // funnel tests pin the gh-241 #5e contract against it.
          homeDir: '/home',
          runtimeTools: tinyTools(const ['read', 'bash']),
          // The overstating catalog: 20k advertised, the fake endpoint
          // refuses at ~800 tokens — the loop's own over-window guard
          // must NOT trip (the request stays under 20k); the refusal
          // must come from the endpoint, and the probable-overflow gate
          // (≥ 50% of the catalog window) must fire on the refused
          // history.
          model: Model(
            id: 'gemini-fake-argon',
            api: 'openai-completions',
            provider: 'openai',
            baseUrl: 'https://example.test/v1',
            contextWindow: 20000,
            maxTokens: 4096,
          ),
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          modelRolesResolver: ModelRolesResolver(
            config: ModelRolesConfig(
              roles: {
                'smol': [ModelRef(provider: 'openai', modelId: 'smol-fake')],
              },
            ),
            secrets: const {'OPENAI_API_KEY': 'k'},
            streamFactory: (kind, apiKey) => smol.call,
          ),
          compactionEngine: CompactionEngine.classic,
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 100,
          ),
          initialOverheadCalibration: const OverheadCalibration(
            1.0,
            measured: true,
          ),
        ),
        io: io,
        // Production wires the ladder inside the catalog adapter; tests
        // wrap the fake explicitly (the connection-retry test's shape).
        streamFunction: transientRetryStreamFunction(poisoned.call),
      );

      final exitCode = await cli.runHeadless('count the words');

      // (a) the ladder spent its budget and the funnel relieved: the
      // turn DROVE TO COMPLETION on the compacted transcript.
      expect(exitCode, 0, reason: 'the continued turn finished normally');

      // (b) the probable-overflow classification rendered.
      expect(
        io.out.toString(),
        contains('probable overflow'),
        reason: 'the classified console line names the class',
      );

      // The refusal really came from the endpoint (three refused calls —
      // the configured retry budget), never from the loop's guard.
      expect(poisoned.refusedCalls, 3, reason: 'the configured retries');

      // (c)+(d) the funnel ran: the continuation request no longer
      // carries the poison — the transcript the continuation rides was
      // compacted (the big read result is gone; the summary rides).
      final served = poisoned.servedContexts;
      expect(served, hasLength(2), reason: 'initial turn + continuation');
      expect(servedLastText(served.first), isNot(contains('task complete')));
      final continuationText = servedLastText(served.last);
      expect(
        continuationText,
        isNot(contains('x' * 45)),
        reason: 'the poisonous payload does not re-send (AC d)',
      );
      // The continuation is the class-aware notice, not a bare retry.
      expect(continuationText, contains('provider refused this exact'));
      expect(continuationText, contains('Continue the interrupted task'));

      // The compaction really ran through the healthy smol role.
      expect(smol.calls, 1, reason: 'one summarizer call served the pass');
      // The visible transcript settled on the completed task.
      expect(io.out.toString(), contains('task complete after the compaction'));
    },
  );
}

/// The full text of the LAST user message in a served request (the
/// continuation notice rides there — the same assertion shape the
/// over-window funnel tests use).
String servedLastText(Context context) {
  final users = context.messages.whereType<UserMessage>().toList();
  return users.isEmpty ? '' : userMessageText(users.last.content);
}

/// A scripted stream that refuses oversized requests with the ticket's
/// exact deterministic failure (`Provider finish_reason: error`, the
/// raw verdict riding `rawStopReason` — the #312 unknown class the
/// ladder replays) and serves the scripted turns otherwise.
final class PoisonedStream {
  PoisonedStream({required this.refusalOverChars, required this.turns});

  final int refusalOverChars;
  final List<List<AssistantMessageEvent>> turns;

  var refusedCalls = 0;
  final servedContexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final chars = estimatedRequestChars(context);
    if (chars > refusalOverChars) {
      refusedCalls++;
      final stream = AssistantMessageEventStream();
      scheduleMicrotask(() {
        stream.push(
          ErrorEvent(
            reason: StopReason.error,
            error: AssistantMessage(
              content: const [],
              api: model.api,
              provider: model.provider,
              model: model.id,
              usage: Usage.zero,
              stopReason: StopReason.error,
              rawStopReason: 'error',
              errorMessage: 'Provider finish_reason: error',
              timestamp: DateTime.utc(2026),
            ),
          ),
        );
        stream.end();
      });
      return stream;
    }
    servedContexts.add(context);
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }

  static int estimatedRequestChars(Context context) {
    var chars = context.systemPrompt?.length ?? 0;
    for (final message in context.messages) {
      final content = switch (message) {
        UserMessage() => message.content,
        AssistantMessage() => message.content,
        ToolResultMessage() => message.content,
        _ => null,
      };
      if (content is String) {
        chars += content.length;
      } else if (content is List<ContentBlock>) {
        for (final block in content) {
          if (block is TextContent) chars += block.text.length;
        }
      }
    }
    return chars;
  }
}
