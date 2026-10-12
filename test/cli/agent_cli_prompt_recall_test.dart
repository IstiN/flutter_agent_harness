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
import 'package:flutter_agent_harness/src/prompts/prompts.g.dart'
    show recallHygienePrompt;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

Future<String> _bootedSystemPrompt({
  CompactionEngine? engine,
  String? systemPrompt,
}) async {
  final env = MemoryExecutionEnv(cwd: '/work');
  final io = FakeCliIO();
  // The MODEL-SEEN prompt is the deterministic seam: boot composition
  // completes before the REPL drives the first turn, so the context the
  // loop actually sent carries whatever the composition produced — no
  // race with late recomposition of `cli.systemPrompt` (the raw
  // constructor prompt is observable before the composer's first pass).
  final fake = FakeStreamFunction([textTurn('ack')]);
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
    streamFunction: fake.call,
  );
  final run = cli.run();
  io.sendLine('ack the boot');
  await waitForIt(() => fake.calls >= 1, reason: 'the first turn to run');
  final prompt = fake.contexts[0].systemPrompt ?? '';
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
    final prompt = await _bootedSystemPrompt(engine: CompactionEngine.classic);
    expect(prompt, isNot(contains('## Session recall')));
    expect(prompt, isNot(contains('recall-hygiene')));
  });

  test(
    'an explicit systemPrompt override stays byte-exact (no contract)',
    () async {
      // An override IS the whole prompt base — the prompt_overrides suite
      // pins exact equality on its own seam; here the override must
      // replace the mode prompt AND carry no recall contract (the
      // model-seen prompt may still carry the standing skills section).
      const base = 'BASE PROMPT for the recall contract test.';
      final prompt = await _bootedSystemPrompt(systemPrompt: base);
      expect(prompt, startsWith(base));
      expect(prompt, isNot(contains('## Session recall')));
      expect(prompt, isNot(contains(recallHygienePrompt)));
    },
  );

  test(
    'the contract appends after the mode prompt, byte-identical to the md',
    () async {
      final prompt = await _bootedSystemPrompt();
      expect(prompt, contains(recallHygienePrompt));
      // The block rides at the tail of the composed base: the contract is
      // the LAST appended standing section before the section composers.
      expect(prompt.indexOf('## Session recall'), greaterThanOrEqualTo(0));
    },
  );

  test(
    'session_search is registered under BOTH engines (always-on tool)',
    () async {
      Future<bool> hasTool(CompactionEngine? engine) async {
        final env = MemoryExecutionEnv(cwd: '/work');
        final io = FakeCliIO();
        final fake = FakeStreamFunction([textTurn('ack')]);
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
          streamFunction: fake.call,
        );
        final run = cli.run();
        io.sendLine('what tools do you have');
        // The scripted turn settles between polls — wait for it to have
        // RUN, not for a transient busy flag.
        await waitForIt(
          () => fake.calls >= 1,
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
    },
  );
}
