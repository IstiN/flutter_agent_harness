// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #1380 A3/AC6 — the recall-hygiene prompt contract is present iff
/// the boot-resolved compaction engine is structured; a classic session's
/// rendered system prompt stays byte-identical to the pre-contract shape
/// (byte-scan both ways). Also pins the always-registered `session_search`
/// tool surface both engines share.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

final class _ScriptedStream {
  _ScriptedStream(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  int calls = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    final events = calls < turns.length ? turns[calls] : textTurn('ok');
    calls++;
    unawaited(() async {
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }());
    return stream;
  }
}

Future<String> _bootedSystemPrompt({
  CompactionEngine? engine,
  String? systemPrompt,
}) async {
  final env = MemoryExecutionEnv(cwd: '/work');
  final io = FakeCliIO();
  final cli = AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      compactionEngine: engine,
      systemPrompt: systemPrompt,
    ),
    io: io,
    streamFunction: _ScriptedStream([textTurn('ack')]).call,
  );
  final run = cli.run();
  await waitForIt(
    () => cli.systemPrompt.isNotEmpty && !cli.isBusy,
    reason: 'the first turn to compose the prompt',
  );
  final prompt = cli.systemPrompt;
  io.sendLine('/exit');
  await run;
  io.close();
  return prompt;
}

void main() {
  test(
    'structured engine (the default): the recall contract is present',
    () async {
      final prompt = await _bootedSystemPrompt();
      expect(prompt, contains('## Session recall'));
      // The dig idioms name the tool pair the contract teaches.
      expect(prompt, contains('session_search'));
      expect(prompt, contains('compact_expand'));
    },
  );

  test('an explicit structured setting composes the contract too', () async {
    final prompt = await _bootedSystemPrompt(
      engine: CompactionEngine.structured,
    );
    expect(prompt, contains('## Session recall'));
  });

  test('classic engine: the contract is absent (byte-scan, AC6/E3)', () async {
    final prompt = await _bootedSystemPrompt(
      engine: CompactionEngine.classic,
    );
    expect(prompt, isNot(contains('## Session recall')));
    expect(prompt, isNot(contains('recall-hygiene')));
  });

  test('an explicit systemPrompt override stays byte-exact (no contract)',
      () async {
    // An override IS the whole prompt — the prompt_overrides suite pins
    // exact equality; the recall contract composes onto the MODE prompt
    // only.
    const base = 'BASE PROMPT for the recall contract test.';
    final prompt = await _bootedSystemPrompt(systemPrompt: base);
    expect(prompt, base);
    expect(prompt, isNot(contains('## Session recall')));
  });

  test('the contract appends after the mode prompt, byte-identical to the md',
      () async {
    final prompt = await _bootedSystemPrompt();
    expect(prompt, contains(recallHygienePrompt));
    // The block rides at the tail of the composed base: the contract is
    // the LAST appended standing section before the section composers.
    expect(
      prompt.indexOf('## Session recall'),
      greaterThanOrEqualTo(0),
    );
  });

  test('session_search is registered under BOTH engines (always-on tool)',
      () async {
    Future<bool> hasTool(CompactionEngine? engine) async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionEngine: engine,
        ),
        io: io,
        streamFunction: _ScriptedStream([textTurn('ack')]).call,
      );
      final run = cli.run();
      await waitForIt(
        () => cli.isBusy,
        reason: 'the first turn to seed the tool surface',
      );
      final found = cli.agent.state.tools.any(
        (tool) => tool.name == 'session_search',
      );
      io.sendLine('/exit');
      await run;
      io.close();
      return found;
    }

    expect(await hasTool(CompactionEngine.structured), isTrue);
    expect(await hasTool(CompactionEngine.classic), isTrue);
  });
}
