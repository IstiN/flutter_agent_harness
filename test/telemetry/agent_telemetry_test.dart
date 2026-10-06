/// Issue #1322 Gap 3 — the pure-core telemetry adapter: the CLI's fa.log
/// phase map (run/turn/tool start+end) extended with the in-process
/// records the CLI cannot have (requestStart, firstToken) and the
/// provider HTTP status on the terminal error record.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
}) => AssistantMessage(
  content: content,
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: stopReason,
  errorMessage: errorMessage,
  timestamp: DateTime.utc(2026),
);

/// A scripted turn: stream start, text delta, done.
AssistantMessageEventStream _textTurn() {
  final stream = AssistantMessageEventStream();
  final empty = _assistant();
  final partial = _assistant(content: [const TextContent(text: 'hi')]);
  stream.push(StartEvent(partial: empty));
  stream.push(TextDeltaEvent(contentIndex: 0, delta: 'hi', partial: partial));
  stream.push(DoneEvent(reason: StopReason.stop, message: partial));
  return stream;
}

AssistantMessageEventStream _errorTurn(String message) {
  final stream = AssistantMessageEventStream();
  stream.push(StartEvent(partial: _assistant()));
  stream.push(
    ErrorEvent(
      reason: StopReason.error,
      error: _assistant(stopReason: StopReason.error, errorMessage: message),
    ),
  );
  return stream;
}

void main() {
  group('AgentTelemetry (the agent → sink adapter)', () {
    test(
      'a clean run produces the CLI phase map plus the provider records',
      () async {
        final sink = InMemoryTelemetrySink();
        final telemetry = AgentTelemetry(sink);
        final agent = Agent(
          model: _model,
          systemPrompt: 's',
          toolExecutor: _okExecutor,
          streamFunction: telemetry.wrapStreamFunction((m, c, {cancelToken}) {
            return _textTurn();
          }),
        );
        telemetry.attach(agent);
        await agent.prompt('hi');

        final kinds = sink.events.map((e) => e.kind).toList();
        expect(
          kinds,
          // requestStart/firstToken are the wrap's; the rest mirror the
          // CLI's fa.log lines one for one.
          [
            AgentTelemetryEventKind.runStart,
            AgentTelemetryEventKind.turnStart,
            AgentTelemetryEventKind.requestStart,
            AgentTelemetryEventKind.firstToken,
            AgentTelemetryEventKind.turnEnd,
            AgentTelemetryEventKind.runEnd,
          ],
        );
        final request = sink.events.firstWhere(
          (e) => e.kind == AgentTelemetryEventKind.requestStart,
        );
        expect(request.detail, contains('model=test-model'));
        // The wrap names the request context on BOTH provider-leg records.
        final firstToken = sink.events.firstWhere(
          (e) => e.kind == AgentTelemetryEventKind.firstToken,
        );
        expect(firstToken.detail, contains('model=test-model'));
        final runEnd = sink.events.last;
        expect(runEnd.sinceRunStart, greaterThanOrEqualTo(Duration.zero));
        // No error → no status claimed on the clean run's terminal record.
        expect(runEnd.httpStatus, isNull);
      },
    );

    test('an aborted run is a phase outcome, never a run error', () async {
      final sink = InMemoryTelemetrySink();
      final telemetry = AgentTelemetry(sink);
      final stream = AssistantMessageEventStream();
      stream.push(StartEvent(partial: _assistant()));
      final agent = Agent(
        model: _model,
        systemPrompt: 's',
        toolExecutor: _okExecutor,
        streamFunction: telemetry.wrapStreamFunction((m, c, {cancelToken}) {
          // The abort terminal mirrors agent_loop's own: an errorMessage
          // RIDES the aborted message — and must not become a run error.
          cancelToken?.onCancel.then((_) {
            stream.push(
              ErrorEvent(
                reason: StopReason.aborted,
                error: _assistant(
                  stopReason: StopReason.aborted,
                  errorMessage: 'Operation aborted',
                ),
              ),
            );
          });
          return stream;
        }),
      );
      telemetry.attach(agent);
      final run = agent.prompt('hi');
      agent.abort();
      await run;

      // `turn end stop=aborted` carries the distinction, `run end` closes
      // the run — and NO `error` record lands (the CLI logs aborted runs
      // as a plain run end, no error line).
      expect(
        sink.events.map((e) => e.kind),
        isNot(contains(AgentTelemetryEventKind.error)),
      );
      final turnEnd = sink.events.firstWhere(
        (e) => e.kind == AgentTelemetryEventKind.turnEnd,
      );
      expect(turnEnd.stopReason, 'aborted');
      expect(sink.events.last.kind, AgentTelemetryEventKind.runEnd);
    });

    test(
      'an in-stream provider error records the parsed HTTP status',
      () async {
        final sink = InMemoryTelemetrySink();
        final telemetry = AgentTelemetry(sink);
        final agent = Agent(
          model: _model,
          systemPrompt: 's',
          toolExecutor: _okExecutor,
          streamFunction: telemetry.wrapStreamFunction((m, c, {cancelToken}) {
            // formatProviderError's own shape for a ProviderHttpError.
            return _errorTurn('429: rate limited');
          }),
        );
        telemetry.attach(agent);
        await agent.prompt('hi');

        final error = sink.events.firstWhere(
          (e) => e.kind == AgentTelemetryEventKind.error,
        );
        expect(error.httpStatus, 429);
        expect(error.detail, '429: rate limited');
        final runEnd = sink.events.last;
        expect(runEnd.kind, AgentTelemetryEventKind.runEnd);
        // The failed run's terminal record does not dress up as a status.
        expect(runEnd.httpStatus, isNull);
      },
    );

    test('a provider exception thrown before the stream is converted to '
        'the providers-never-throw shape', () async {
      final sink = InMemoryTelemetrySink();
      final telemetry = AgentTelemetry(sink);
      final agent = Agent(
        model: _model,
        systemPrompt: 's',
        toolExecutor: _okExecutor,
        streamFunction: telemetry.wrapStreamFunction((m, c, {cancelToken}) {
          throw const ProviderHttpError(502, 'bad gateway');
        }),
      );
      telemetry.attach(agent);
      await agent.prompt('hi');

      final error = sink.events.firstWhere(
        (e) => e.kind == AgentTelemetryEventKind.error,
      );
      expect(error.httpStatus, 502);
      expect(error.detail, '502: bad gateway');
    });

    test(
      'a hanging request is visible as requestStart with no firstToken',
      () async {
        final sink = InMemoryTelemetrySink();
        final telemetry = AgentTelemetry(sink);
        final neverAnswered = AssistantMessageEventStream();
        final agent = Agent(
          model: _model,
          systemPrompt: 's',
          toolExecutor: _okExecutor,
          streamFunction: telemetry.wrapStreamFunction((m, c, {cancelToken}) {
            return neverAnswered;
          }),
        );
        telemetry.attach(agent);
        unawaited(agent.prompt('hi'));
        // Let the loop reach the request.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          sink.events.map((e) => e.kind),
          contains(AgentTelemetryEventKind.requestStart),
        );
        expect(
          sink.events.map((e) => e.kind),
          isNot(contains(AgentTelemetryEventKind.firstToken)),
        );
        agent.abort();
        neverAnswered.end();
        await agent.waitForIdle();
      },
    );

    test('the in-memory ring keeps the last [capacity] records', () {
      final sink = InMemoryTelemetrySink(capacity: 3);
      for (var i = 0; i < 5; i++) {
        sink.record(
          AgentTelemetryEvent(
            kind: AgentTelemetryEventKind.turnStart,
            timestamp: DateTime.utc(2026),
            sinceRunStart: Duration(milliseconds: i),
          ),
        );
      }
      expect(sink.events.length, 3);
      expect(sink.events.first.sinceRunStart, const Duration(milliseconds: 2));
      expect(sink.events.last.sinceRunStart, const Duration(milliseconds: 4));
    });

    test('a throwing sink never breaks the run', () async {
      final telemetry = AgentTelemetry(_ThrowingSink());
      final agent = Agent(
        model: _model,
        systemPrompt: 's',
        toolExecutor: _okExecutor,
        streamFunction: (m, c, {cancelToken}) => _textTurn(),
      );
      telemetry.attach(agent);
      await agent.prompt('hi');
      // Reaching here is the assertion: the sink threw on every record.
    });
  });
}

final class _ThrowingSink implements AgentTelemetrySink {
  @override
  void record(AgentTelemetryEvent event) => throw StateError('broken sink');
}

Future<ToolExecutionResult> _okExecutor(
  ToolCall toolCall,
  CancelToken? cancelToken,
  ToolUpdateCallback? onUpdate,
) async => ToolExecutionResult.text('ok');
