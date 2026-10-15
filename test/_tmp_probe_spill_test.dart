// TEMPORARY probe for the CI flake in agent_cli_spilling_test.dart
// (L4/AC1 byte-identical): runs the legacy rig N times and prints each
// run's systemPromptChars + saves the raw trajectory_prompt_blob text, so
// the per-run variable-length pieces can be diffed. NOT for landing.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'cli/agent_cli_test_support.dart';

Future<void> main() async {
  final lengths = <int>[];
  for (var i = 0; i < 10; i++) {
    final turns = [
      toolTurn([
        ToolCall(id: 'c1', name: 'bash', arguments: {'command': 'cat big.log'}),
      ]),
      textTurn('done'),
    ];
    final env = MemoryExecutionEnv(
      cwd: '/work',
      shell: FakeShell(stdout: 'x' * 60000),
    );
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final io = FakeCliIO();
    final fake = FakeStreamFunction(turns);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'k',
        env: env,
        sessionRoot: '/sessions-$i',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
        compactionEngine: CompactionEngine.classic,
      ),
      io: io,
      streamFunction: fake.call,
    );
    final run = cli.run();
    io.sendLine('go');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    io.sendLine('/exit');
    await run;
    // Pull the session JSONL out of the in-memory env.
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions-$i');
    final meta = (await repo.list(cwd: '/work')).single;
    final jsonl = (await env.readTextFile(meta.path)).valueOrNull!;
    final chars = RegExp(r'"systemPromptChars":(\d+)')
        .firstMatch(jsonl)
        ?.group(1);
    lengths.add(int.parse(chars!));
    // Save the prompt blob text of this run.
    final blobLine = jsonl
        .split('\n')
        .firstWhere((l) => l.contains('trajectory_prompt_blob'));
    final data =
        (jsonDecode(blobLine) as Map)['data'] as Map<String, dynamic>;
    File('/tmp/probe_prompt_$i.txt').writeAsStringSync(data['text'] as String);
  }
  print('LENGTHS=$lengths');
}
