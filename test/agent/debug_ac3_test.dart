import 'dart:async';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage _assistant({List<ContentBlock> content = const [], StopReason stopReason = StopReason.stop, String? errorMessage}) =>
    AssistantMessage(content: content, api: 't', provider: 't', model: 'm', usage: Usage.zero, stopReason: stopReason, errorMessage: errorMessage, timestamp: DateTime.utc(2026));

void main() {
  test('debug ac3', () async {
    final readyAt = DateTime.now().add(const Duration(milliseconds: 500));
    var calls = 0;
    final fires = <String>[];
    final agent = Agent(
      model: Model(id: 'm', api: 't', provider: 't', baseUrl: 'https://x.test', contextWindow: 1, maxTokens: 1),
      streamFunction: transientRetryStreamFunction((model, context, {cancelToken}) {
        calls++;
        final c = calls;
        final stream = AssistantMessageEventStream();
        unawaited(() async {
          final remaining = readyAt.difference(DateTime.now());
          print('attempt $c start, remaining ${remaining.inMilliseconds}ms');
          if (!remaining.isNegative) {
            final cancelled = (cancelToken?.onCancel ?? Completer<void>().future).then<bool>((_) => true);
            final waited = await Future.any([Future<void>.delayed(remaining).then<bool>((_) => false), cancelled]);
            print('attempt $c done waiting, cancelled=$waited');
            if (waited) {
              stream..push(ErrorEvent(reason: StopReason.aborted, error: _assistant(stopReason: StopReason.aborted, errorMessage: 'Request was aborted')))..end();
              return;
            }
          }
          for (final e in [StartEvent(partial: _assistant()), DoneEvent(reason: StopReason.stop, message: _assistant(content: [TextContent(text: 'ok')]))]) {
            stream.push(e);
          }
          stream.end();
        }());
        return stream;
      }, delay: const Duration(milliseconds: 5)),
      toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      runIdleTimeout: const Duration(milliseconds: 60),
      onRunIdleTimeout: (e) => fires.add('$e'),
    );
    await agent.prompt('hi');
    await agent.waitForIdle();
    print('calls=$calls fires=$fires');
    final last = agent.state.messages.last as AssistantMessage;
    print('last stop=${last.stopReason} err=${last.errorMessage?.substring(0, 120)}');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
