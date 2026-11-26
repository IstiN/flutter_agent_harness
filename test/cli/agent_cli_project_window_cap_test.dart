// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// gh-2411 follow-up #5b (owner live test, 21:29): the PROJECT
// `.fah/config.yaml` `agent.contextWindowCap` is honored by the CLI —
// through the loader the app already uses — and the boot log names the
// setting that won (`context window cap source=project window=25000`).

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

Model get _model => const Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 200000,
  maxTokens: 4096,
);

void main() {
  late FakeCliIO io;

  setUp(() {
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  test('a project contextWindowCap caps the window (the existing resolution '
      'seam) and the boot log says the project set it', () async {
    const cap = 25000;
    // The window math is unchanged: min(model window, cap).
    expect(
      resolveCompactionHostWiring(
        mainModel: _model,
        contextWindowCap: cap,
      ).window,
      cap,
    );
    final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final stream = FakeStreamFunction([textTurn('ok')]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: _model,
        apiKey: '[REDACTED:Sensitive-Value]',
        env: env,
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
        systemPrompt: tinyPrompt,
        runtimeTools: tinyTools(const ['bash']),
        contextWindowCap: cap,
        contextWindowCapSource: 'project',
      ),
      io: io,
      streamFunction: stream.call,
    );

    final exit = await cli.runHeadless('hello');
    expect(exit, 0, reason: io.out.toString());

    final log = (await env.readTextFile('/home/.fah/logs/fa.log')).getOrThrow();
    // The diagnostic log prefixes each line with its timestamp and level.
    expect(log, contains('context window cap source=project window=25000'));
  });
}
