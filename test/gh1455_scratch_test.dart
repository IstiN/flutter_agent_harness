import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  test('scratch: bash_job stop must not cancel the run token', timeout: Timeout(Duration(minutes: 3)), () async {
    final ws = await Directory.systemTemp.createTemp('gh1455_');
    final env = LocalExecutionEnv(cwd: ws.path);
    final jobs = ShellJobRegistry(env: env);
    final registry = ToolRegistry([
      shellTool(env, jobs: jobs),
      bashJobTool(jobs),
    ]);
    final events = <AgentEvent>[];
    Object? runTokenCancelledAt;

    late StreamFunction stream;
    var turn = 0;
    stream = (model, context, {cancelToken}) {
      turn++;
      final s = AssistantMessageEventStream();
      if (turn == 1) {
        // Start a long background job.
        s.push(
          StartEvent(partial: AssistantMessage(content: const [], api: 't', provider: 't', model: 'm', usage: Usage.zero, stopReason: StopReason.stop, timestamp: DateTime.now())),
        );
        final call = ToolCall(
          id: 'c1',
          name: 'bash',
          arguments: {'command': 'sleep 30', 'background': true},
        );
        s.push(
          ToolCallStartEvent(contentIndex: 0, partial: AssistantMessage(content: const [], api: 't', provider: 't', model: 'm', usage: Usage.zero, stopReason: StopReason.toolUse, timestamp: DateTime.now())),
        );
        s.push(
          ToolCallEndEvent(contentIndex: 0, toolCall: call, partial: AssistantMessage(content: [call], api: 't', provider: 't', model: 'm', usage: Usage.zero, stopReason: StopReason.toolUse, timestamp: DateTime.now())),
        );
        s.push(DoneEvent(reason: StopReason.toolUse, message: AssistantMessage(content: [call], api: 't', provider: 't', model: 'm', usage: Usage.zero, stopReason: StopReason.toolUse, timestamp: DateTime.now())));
        s.end();
        return s;
      }
      // Turn 2: stop the job + a foreground bash in ONE batch (parallel).
      final jobId = jobs.jobs.first.id;
      final stop = ToolCall(
        id: 'c2',
        name: 'bash_job',
        arguments: {'action': 'stop', 'id': jobId},
      );
      final bash = ToolCall(
        id: 'c3',
        name: 'bash',
        arguments: {'command': 'echo next-call-ran'},
      );
      final partial = AssistantMessage(content: [stop, bash], api: 't', provider: 't', model: 'm', usage: Usage.zero, stopReason: StopReason.toolUse, timestamp: DateTime.now());
      s.push(StartEvent(partial: AssistantMessage(content: const [], api: 't', provider: 't', model: 'm', usage: Usage.zero, stopReason: StopReason.stop, timestamp: DateTime.now())));
      s.push(ToolCallStartEvent(contentIndex: 0, partial: partial));
      s.push(ToolCallEndEvent(contentIndex: 0, toolCall: stop, partial: partial));
      s.push(ToolCallStartEvent(contentIndex: 1, partial: partial));
      s.push(ToolCallEndEvent(contentIndex: 1, toolCall: bash, partial: partial));
      s.push(DoneEvent(reason: StopReason.toolUse, message: partial));
      s.end();
      return s;
    };

    final agent = Agent(
      toolRegistry: registry,
      streamFunction: stream,
      toolExecution: ToolExecutionMode.parallel,
      stuckTool: const StuckToolConfig(), // headless default
    );
    agent.subscribe((event, token) async {
      events.add(event);
      if (event is ToolExecutionEndEvent &&
          event.toolName == 'bash_job' &&
          token.isCancelled) {
        runTokenCancelledAt ??= 'bash_job end';
      }
    });

    await agent.prompt('go');
    await jobs.env.createDir('/tmp').then((_) {});
    final last = agent.state.messages.whereType<AssistantMessage>().last;
    // ignore: avoid_print
    print('final stopReason: ${last.stopReason} err=${last.errorMessage}');
    for (final m in agent.state.messages.whereType<ToolResultMessage>()) {
      // ignore: avoid_print
      print('tool ${m.toolName}: ${m.content.whereType<TextContent>().map((t) => t.text).join().substring(0, 80.clamp(0, m.content.whereType<TextContent>().map((t) => t.text).join().length))} isError=${m.isError}');
    }
    // ignore: avoid_print
    print('tokenCancelledDuringStop: $runTokenCancelledAt');
    await ws.delete(recursive: true);
  });
}
