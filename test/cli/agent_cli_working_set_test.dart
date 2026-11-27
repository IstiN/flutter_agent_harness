// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2423 C1 — IT-1 through a REAL booted CLI (fake stream, memory env):
/// the `working_set` tool call lands a `custom` record in the agent's own
/// session, the NEXT request carries the `<working-set>` block in the
/// SYSTEM channel (never a message), the dim line reports the write, the
/// CLI prompt carries the two new includes (C1 + C7), and a resumed
/// session (`--resume`) reads the snapshot back from the file (AC1, AC2,
/// AC3, AC11).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _notes = 'decisions: ship it\nred list: never push\nnext: changelog';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() async {
    env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    // Suppress session-start memory maintenance (the agent_cli_test
    // pattern) so the scripted turns feed only the turn under test.
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cli(
    FakeStreamFunction stream, {
    bool resume = false,
    MemoryExecutionEnv? on,
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive-Value]',
      env: on ?? env,
      sessionRoot: '/sessions',
      sessionName: 'working-set-it',
      resume: resume,
      providerKind: 'openai-completions',
    ),
    io: io,
    streamFunction: stream.call,
  );

  Future<Session> openSession() async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessions = await repo.list(cwd: '/work');
    return repo.open(sessions.single);
  }

  test(
    'write → record → the next request carries the block in the system '
    'channel',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = FakeStreamFunction([
        toolTurn([
          ToolCall(id: 'w1', name: 'working_set', arguments: {'text': _notes}),
        ]),
        textTurn('done'),
      ]);
      final code = await cli(stream).runHeadless('go');
      expect(code, 0, reason: io.out.toString());

      // Two requests: the prompt, then the one after the tool result.
      expect(stream.contexts, hasLength(2));
      final first = stream.contexts[0].systemPrompt!;
      final second = stream.contexts[1].systemPrompt!;
      expect(
        first,
        isNot(contains('<working-set source="agent" updated="')),
        reason: 'no snapshot yet (I3)',
      );
      expect(
        second,
        endsWith(
          '\n<working-set source="agent" updated="'
          '${second.substring(second.lastIndexOf('updated="') + 9, second.lastIndexOf('updated="') + 14)}">'
          '\n$_notes\n</working-set>',
        ),
      );
      expect(
        second,
        startsWith(first.substring(0, first.length - 1).substring(0, 200)),
        reason: 'the static prompt stays a byte-stable prefix (F1)',
      );
      // The block is system channel — never a user message (I2).
      for (final context in stream.contexts) {
        expect(
          context.messages.whereType<UserMessage>().where(
            (m) => userMessageText(m.content).contains('<working-set'),
          ),
          isEmpty,
        );
      }
      // The agent saw the card's result text.
      final toolResults = [
        for (final context in stream.contexts)
          ...context.messages.whereType<ToolResultMessage>(),
      ];
      expect(
        toolResults.map((r) => userMessageText(r.content)),
        contains(
          contains(
            'working set saved: ${_notes.length} chars — '
            'pinned in every request, survives compaction',
          ),
        ),
      );
      // The CLI prompt carries both #2423 includes (AC11).
      expect(first, contains('## Working set — your status, pinned'));
      expect(first, contains('## Context hygiene'));
      // One dim line for the human.
      expect(
        io.out.toString(),
        contains('working set updated (${_notes.length} chars)'),
      );
      // The record: a `custom` working_set entry in the agent's OWN session.
      final session = await openSession();
      final records = (await session.getEntries())
          .whereType<CustomRecord>()
          .where((r) => r.customType == workingSetRecordType)
          .toList();
      expect(records, hasLength(1));
      expect(workingSetFromPayload(records.single.data)!.text, _notes);
    },
  );

  test(
    'resume reads the snapshot from the file: the first request after a '
    'restart carries the block; a clear removes it',
    timeout: const Timeout(Duration(seconds: 180)),
    () async {
      final first = FakeStreamFunction([
        toolTurn([
          ToolCall(id: 'w1', name: 'working_set', arguments: {'text': _notes}),
        ]),
        textTurn('done'),
      ]);
      expect(await cli(first).runHeadless('go'), 0);

      // "kill -9 + restart": a NEW CLI over the same env resumes by name.
      final resumed = FakeStreamFunction([
        toolTurn([
          ToolCall(id: 'w2', name: 'working_set', arguments: {'text': ''}),
        ]),
        textTurn('done'),
      ]);
      expect(await cli(resumed, resume: true).runHeadless('continue'), 0);
      expect(
        resumed.contexts[0].systemPrompt,
        endsWith('\n$_notes\n</working-set>'),
        reason: 'the first request after the restart carries the block',
      );
      // The clear lands on the next request and nowhere else.
      expect(
        resumed.contexts[1].systemPrompt,
        isNot(contains('<working-set source="agent" updated="')),
      );
      expect(io.out.toString(), contains('working set cleared'));
      final session = await openSession();
      expect((await session.workingSetSnapshot())!.isClear, isTrue);
    },
  );
}
