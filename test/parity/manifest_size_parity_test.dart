/// The default-manifest size gate (GOAL #28, issue #2416 AC9 / REG-1):
/// the default partition's boot manifest — keep-12 ∩ capabilities +
/// `others` with the 18 CLI deferred names in the stub — is pinned at
/// ≤ 21,000 wire chars (keep-12 + stub ≈ 19,100 × 1.10, rounded down),
/// computed from the REAL tool objects the provider serializes (not the
/// ledger). Same standing as hello_token_parity: RED BLOCKS MERGE ON ITS
/// OWN — a description or schema creep past the pin fails this test and
/// the eroding saving is visible in CI, not in a session three months
/// later.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

/// The GOAL #28 pin: keep-12 + `others` ≈ 19,100 wire chars × 1.10
/// headroom, rounded down. The `enum` variant of the stub (+250 chars)
/// also fits under it.
const defaultManifestWireCharsMax = 21000;

/// Wire chars of one tool as the providers serialize it: name +
/// description + compact JSON schema + ~40 chars of envelope
/// (`{name, description, input_schema}` on Anthropic,
/// `{type: function, function: {…}}` on OpenAI-compatible) — the same
/// accounting the GOAL's measured baseline used.
int toolWireChars(Tool tool) =>
    tool.name.length +
    tool.description.length +
    jsonEncode(tool.parameters).length +
    40;

void main() {
  test('AC9: the default boot manifest is ≤ $defaultManifestWireCharsMax '
      'wire chars (hard REG gate)', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final io = FakeCliIO();
    final stream = FakeStreamFunction([textTurn('ok')]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        homeDir: '/home/u',
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        loadMode: AgentLoadMode.defaultMode,
      ),
      io: io,
      streamFunction: stream.call,
    );
    final run = cli.run();
    await io.out.waitUntilContains('fa>', reason: 'boot prompt');
    io.sendLine('hello');
    await waitForIt(() => stream.calls >= 1, reason: 'hello turn');
    io.sendLine('/exit');
    await run;
    io.close();

    final tools = stream.contexts.first.tools ?? const <Tool>[];
    final names = tools.map((t) => t.name).toSet();

    // The stub must be present and carry the 17 CLI deferred names
    // (the fake env registers every one of them enabled).
    final others = tools.where((t) => t.name == 'others').toList();
    expect(others, hasLength(1), reason: 'the discovery stub rides');
    // GOAL #28 review round 2: session_search is always-on (the
    // prompt-recall contract pins it under BOTH engines), so it left the
    // deferred 18 — the stub names 17.
    expect(
      names,
      contains('session_search'),
      reason: 'always-on under both compaction engines',
    );
    for (final deferred in [
      'config',
      'memory_list',
      'memory_delete',
      'schedule_message',
      'ask',
      'request_secret',
      'task_status',
      'task_observe',
      'task_send',
      'task_resume',
      'task_cancel',
      'agent_message',
      'agent_directory',
      'task',
      'checkpoint',
      'rewind',
      'compact_expand',
    ]) {
      expect(
        others.single.description,
        contains(deferred),
        reason: 'the stub names $deferred',
      );
    }
    // Capability-absent conditionals are invisible (AC1/E12 in this
    // env: no media slots, non-OpenRouter main, no lsp/web transports).
    for (final absent in [
      'generate_image',
      'generate_video',
      'decide',
      'inspect_image',
      'lsp',
      'web_search',
      'web_fetch',
    ]) {
      expect(names, isNot(contains(absent)), reason: absent);
    }

    final wireChars = [
      for (final tool in tools) toolWireChars(tool),
    ].fold(0, (a, b) => a + b);
    // Recorded for the PR (GOAL #28 AC9/L3).
    // ignore: avoid_print
    print('default manifest: ${tools.length} tools, $wireChars wire chars');
    expect(wireChars, lessThanOrEqualTo(defaultManifestWireCharsMax));

    // The pin buys −62% versus the measured 50,125-char 34-tool
    // baseline; guard the saving itself so a partial regression (a
    // forgotten demotion) is loud even under the 21k ceiling.
    expect(wireChars, lessThan(50125));
  });
}
