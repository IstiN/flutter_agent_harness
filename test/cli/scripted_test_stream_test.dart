// Unit coverage for the PTY-test scripted provider hook (issue #446 AC1):
// the consumption contract the PTY equivalence test relies on.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/agent/agent_loop.dart'
    show StreamFunction;
import 'package:flutter_agent_harness/src/cli/scripted_test_stream.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/event_stream.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  const context = Context(systemPrompt: 's', messages: []);

  /// A stream function bound to a temp [turns] script file.
  StreamFunction scriptFor(List<Object> turns) {
    final file = File(
      '${Directory.systemTemp.createTempSync().path}/turns.json',
    )..writeAsStringSync(jsonEncode(turns));
    addTearDown(() => file.parent.delete(recursive: true));
    return scriptedTestStreamFunction(file.path)!;
  }

  /// Runs one provider call to completion, returning the done message.
  Future<AssistantMessage> pump(StreamFunction fn) async {
    AssistantMessage? done;
    await for (final event in fn(testModel, context)) {
      if (event is DoneEvent) done = event.message;
    }
    return done!;
  }

  test('streams a text turn verbatim and stops', () async {
    final done = await pump(
      scriptFor([
        [
          {'text': 'hello world'},
        ],
      ]),
    );
    expect(done.stopReason, StopReason.stop);
    expect((done.content.single as TextContent).text, 'hello world');
  });

  test('streams a tool call with toolUse stop reason', () async {
    final done = await pump(
      scriptFor([
        [
          {
            'tool_call': {
              'id': 'c1',
              'name': 'bash',
              'arguments': {'command': 'ls'},
            },
          },
        ],
      ]),
    );
    expect(done.stopReason, StopReason.toolUse);
    final call = done.content.whereType<ToolCall>().single;
    expect(call.id, 'c1');
    expect(call.name, 'bash');
    expect(call.arguments, {'command': 'ls'});
  });

  test('consumes turns in call order, then repeats the last', () async {
    final fn = scriptFor([
      [
        {'text': 'first'},
      ],
      [
        {'text': 'second'},
      ],
    ]);
    String text(AssistantMessage m) => (m.content.single as TextContent).text;
    expect(text(await pump(fn)), 'first');
    expect(text(await pump(fn)), 'second');
    // Exhausted scripts repeat their last turn for any extra provider
    // call (subagents share the process stream).
    expect(text(await pump(fn)), 'second');
  });

  test('a script-less boot yields no scripted function', () {
    expect(scriptedTestStreamFunction(null), isNull);
    expect(scriptedTestStreamFunction('   '), isNull);
  });
}
