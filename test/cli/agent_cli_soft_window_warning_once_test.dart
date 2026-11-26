// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// gh-2411 follow-up #5c (C2 — owner live test round 4): the soft-window
// warning is shown EXACTLY ONCE per session. Run 2 printed the same
// `context window … below the fixed request overhead` line twice: the
// latch keyed on the session id, and a session that carries no id yet
// warned on every sighting.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _warning = 'cannot take a trim below its trigger';

void main() {
  late FakeCliIO io;

  setUp(() => io = FakeCliIO());
  tearDown(() => io.close());

  test(
    'a resumed session in the soft-window regime, three prompts: ONE warning',
    () async {
      final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      // A RESUMED session: at boot the session carries no cached id yet
      // (the owner's run: `sid=-`), the id arrives before the first
      // prompt — the latch must not treat that as a new sighting.
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final seed = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
      );
      await seed.appendSessionName('soft-window-once-target');
      await seed.appendMessage(UserMessage.text('seeded task: the mips one'));
      final stream = FakeStreamFunction([
        textTurn('first answer'),
        textTurn('second answer'),
        textTurn('third answer'),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'tiny-window',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            // Under the ≈2.7k fixed overhead of the merged seam (#2416:
            // the slim manifest shrank the tiny fixture's footprint —
            // prompt composition + bash + working_set schemas ≈2723
            // tokens): trigger = window − reserve = 3400 − 1024 = 2376
            // < 2723 — the soft-window regime on every prompt — while
            // the estimate stays UNDER the window (the skip-and-warn
            // path, as before).
            contextWindow: 3400,
            maxTokens: 4096,
          ),
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'soft-window-once-target',
          homeDir: '/home',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          compactionEngine: CompactionEngine.structured,
          systemPrompt: tinyPrompt,
          runtimeTools: tinyTools(const ['bash']),
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      await waitForIt(() => cli.agent.state.tools.isNotEmpty);
      for (var turn = 1; turn <= 3; turn++) {
        io.sendLine('prompt $turn zebra');
        await waitForIt(
          () => stream.calls >= turn && !cli.isBusy,
          reason: 'turn $turn settles',
        );
      }
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      // The fixture really is in the regime.
      expect(out, contains(_warning), reason: out);
      expect(
        _warning.allMatches(out),
        hasLength(1),
        reason: 'ONE visible warning per session — never a repeat:\n$out',
      );
      final log = (await env.readTextFile(
        '/home/.fah/logs/fa.log',
      )).valueOrNull;
      expect('soft window sid='.allMatches(log ?? ''), hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
