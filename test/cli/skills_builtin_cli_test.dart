// Issue #1151 CLI surface: the compiled-in built-in skills (`create-goal`,
// `self-settings`) on the terminal host — discovery + `skills:` toggle
// gating (AC1-AC4), the `(builtin)` completion badge (AC5), and the TUI
// completion overlay (AC8). Wave-1 APIs (builtin_skills.dart,
// skill_availability.dart) are exercised through the real AgentCli boot:
// MemoryExecutionEnv + FakeCliIO, no real terminal involved.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  tuiCompletionTests();

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  AgentCli cliFor(
    StreamFunction streamFunction, {
    Map<String, bool> skillToggles = const {},
    Future<void> Function()? onSkillTogglesChanged,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
        skillToggles: skillToggles,
        onSkillTogglesChanged: onSkillTogglesChanged,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  MenuItem? menuRow(AgentCli cli, String prefix, String label) {
    for (final item in cli.slashMenuForTest(prefix)) {
      if (item.label == label) return item;
    }
    return null;
  }

  test(
    'AC1: built-ins resolve and invoke with no project skills at all',
    () async {
      final fake = FakeStreamFunction([textTurn('goal drafted')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () =>
            cli.systemPrompt.contains('<name>create-goal</name>') &&
            cli.systemPrompt.contains('<name>self-settings</name>'),
      );
      // The prompt block points at the virtual builtin:// path (the read
      // tool serves it from the embedded copy).
      expect(
        cli.systemPrompt,
        contains('builtin://skills/create-goal/SKILL.md'),
      );
      // /skills lists them with the builtin scope+source.
      io.sendLine('/skills');
      await waitForIt(
        () => io.out.toString().contains(
          'builtin://skills/create-goal/SKILL.md (builtin, builtin)',
        ),
      );
      // The /<name> alias invokes the builtin and the rendered body enters
      // the run.
      io.sendLine('/create-goal double option pricing');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      expect(
        io.out.toString(),
        contains('skill create-goal — builtin://skills/create-goal/SKILL.md'),
      );
      final lastUser = fake.contexts.last.messages
          .whereType<UserMessage>()
          .last;
      final text = lastUser.content as String;
      expect(text, contains('correction-proof GOAL documents'));
      expect(text, contains('ARGUMENTS: double option pricing'));
    },
  );

  test(
    'AC2: a project skill shadows the same-named builtin; removal restores',
    () async {
      await env.writeFile(
        '/work/.fah/skills/create-goal/SKILL.md',
        '---\nname: create-goal\ndescription: Project goal writer\n---\n'
            'PROJECT COPY body\n',
      );
      var fake = FakeStreamFunction([textTurn('ok')]);
      var cli = cliFor(fake.call);
      var run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>create-goal</name>'),
      );
      // The project copy wins discovery: no builtin:// location anywhere.
      expect(cli.systemPrompt, isNot(contains('builtin://skills/create-goal')));
      io.sendLine('/skills');
      await waitForIt(
        () => io.out.toString().contains(
          'create-goal: builtin skill shadowed by project skill',
        ),
      );
      io.sendLine('/create-goal ship');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      final user = fake.contexts.last.messages.whereType<UserMessage>().last;
      expect(user.content as String, contains('PROJECT COPY body'));
      io.sendLine('/exit');
      await run;

      // Removing the project copy restores the builtin (no shadow note).
      await env.remove('/work/.fah/skills/create-goal', recursive: true);
      // A fresh io: the line stream of the first boot is spent.
      await io.close();
      io = FakeCliIO();
      fake = FakeStreamFunction([textTurn('ok')]);
      cli = cliFor(fake.call);
      run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('builtin://skills/create-goal'),
      );
      io.sendLine('/skills');
      await waitForIt(
        () => io.out.toString().contains('create-goal — Turn a feature'),
      );
      expect(io.out.toString(), isNot(contains('shadowed by')));
      io.sendLine('/exit');
      await run;
    },
  );

  test('AC3: project skills: {create-goal: off} gates every surface', () async {
    await env.writeFile(
      '/work/.fah/config.yaml',
      'skills:\n  create-goal: off\n',
    );
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(
      () => cli.systemPrompt.contains('<name>self-settings</name>'),
    );
    // The prompt block drops the disabled builtin, keeps the enabled one.
    expect(cli.systemPrompt, isNot(contains('<name>create-goal</name>')));
    // Completion drops it too.
    expect(menuRow(cli, '/cre', '/create-goal'), isNull);
    // Invocation names the scope and the way back.
    io.sendLine('/create-goal nope');
    await waitForIt(
      () => io.out.toString().contains('skill create-goal is disabled'),
    );
    expect(io.out.toString(), contains('(project)'));
    expect(io.out.toString(), contains('/skills on create-goal'));
    // The /skills listing shows the off-state in the dim tail.
    io.sendLine('/skills');
    await waitForIt(() => io.out.toString().contains('off (project)'));
    io.sendLine('/exit');
    await run;
  });

  test(
    'AC3: a broken project skills: section is data, not a crash (CQIw)',
    () async {
      await env.writeFile(
        '/work/.fah/config.yaml',
        'skills:\n  create-goal: yes-please\n',
      );
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>create-goal</name>'),
      );

      // Boot survived; the error printed once and the builtins stayed on
      // (no project scope applied, last good = none).
      expect(io.out.toString(), contains('invalid skills section in'));
      expect(
        io.out.toString(),
        contains('project scope ignored, keeping last good'),
      );
      expect(io.out.toString(), isNot(contains('ConfigException')));

      // /skills reload reports the same error without killing the REPL.
      io.sendLine('/skills reload');
      await waitForIt(
        () => io.out.toString().contains('skills: invalid skills section in'),
      );
      io.sendLine('/exit');
      // The REPL unwind-free exit (run() completing) IS the crash-free proof.
      await run;
    },
  );

  test('gh-1409 P2: /skills off|on republishes agent.operativeSkills '
      'in-session', () async {
    // The toggle path recomputes _enabledSkills but (before the fix) never
    // re-published the agent's pin source set — a disabled pin-owning
    // skill kept its operative directives riding every request, an
    // enabled one never started, until a full /skills reload.
    await env.writeFile(
      '/work/.fah/skills/pinny/SKILL.md',
      '---\nname: pinny\ndescription: pin owner\n'
      'operative:\n  - "always cite sources"\n---\nBody.\n',
    );
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(() => cli.systemPrompt.contains('<name>pinny</name>'));
    // Boot published the source set (lifecycle P2).
    expect(cli.agent.operativeSkills.map((s) => s.name), contains('pinny'));

    io.sendLine('/skills off pinny');
    await waitForIt(() => io.out.toString().contains('skills: disabled pinny'));
    expect(
      cli.agent.operativeSkills.map((s) => s.name),
      isNot(contains('pinny')),
    );

    io.sendLine('/skills on pinny');
    await waitForIt(() => io.out.toString().contains('skills: enabled pinny'));
    expect(cli.agent.operativeSkills.map((s) => s.name), contains('pinny'));
    io.sendLine('/exit');
    await run;
  });

  test('AC3: toggling through a valid-yaml invalid-section file is data '
      '(CQIw merge path, review -HUfC)', () async {
    // Syntactically valid yaml whose skills: section carries a
    // non-boolean value: the read path already treated this as data
    // (CQIw); the MERGE path used to let the ConfigException escape and
    // take the line-mode REPL down on `/skills off`.
    await env.writeFile(
      '/work/.fah/config.yaml',
      'skills:\n  other-skill: yes-please\n',
    );
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(
      () => cli.systemPrompt.contains('<name>create-goal</name>'),
    );

    io.sendLine('/skills off create-goal');
    await waitForIt(
      () => io.out.toString().contains('skills: cannot merge project scope'),
    );
    expect(io.out.toString(), contains('skills: cannot merge project scope'));
    expect(io.out.toString(), isNot(contains('ConfigException')));
    // Nothing persisted — the broken section is untouched.
    final file = (await env.readTextFile('/work/.fah/config.yaml')).valueOrNull;
    expect(file, contains('other-skill: yes-please'));
    expect(file, isNot(contains('create-goal')));
    // A failed persist leaves the live state untouched (the arm's
    // contract): create-goal is still listed, and the REPL is alive.
    expect(cli.systemPrompt, contains('<name>create-goal</name>'));
    io.sendLine('/skills reload');
    await waitForIt(() => io.out.toString().contains('reloaded:'));
    io.sendLine('/exit');
    await run;
  });

  test('AC3: global off loses to project on (deepest scope wins)', () async {
    await env.writeFile(
      '/work/.fah/config.yaml',
      'skills:\n  create-goal: on\n',
    );
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, skillToggles: {'create-goal': false});
    final run = cli.run();
    await waitForIt(
      () => cli.systemPrompt.contains('<name>create-goal</name>'),
    );
    io.sendLine('/exit');
    await run;
  });

  test('AC3: unknown toggle id warns once per distinct id', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, skillToggles: {'no-such-skill': true});
    final run = cli.run();
    await waitForIt(
      () => cli.systemPrompt.contains('<name>create-goal</name>'),
    );
    expect(io.out.toString(), contains('toggle "no-such-skill" ignored'));
    // /skills reload re-resolves — the warning must not repeat.
    io.sendLine('/skills reload');
    await waitForIt(() => io.out.toString().contains('reloaded:'));
    expect(
      'toggle "no-such-skill" ignored'.allMatches(io.out.toString()),
      hasLength(1),
    );
    io.sendLine('/exit');
    await run;
  });

  test(
    'AC4: /skills off|on toggles live and persists to the project file',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>create-goal</name>'),
      );
      io.sendLine('/skills off create-goal');
      await waitForIt(
        () => io.out.toString().contains(
          'skills: disabled create-goal (scope: project)',
        ),
      );
      // Same-session effect: prompt + completion recomposed, no restart.
      expect(cli.systemPrompt, isNot(contains('<name>create-goal</name>')));
      expect(menuRow(cli, '/cre', '/create-goal'), isNull);
      // The project scope landed in .fah/config.yaml.
      final file = (await env.readTextFile(
        '/work/.fah/config.yaml',
      )).valueOrNull;
      expect(file, contains('skills:'));
      expect(file, contains('create-goal: false'));
      // Back on through the same arm.
      io.sendLine('/skills on create-goal');
      await waitForIt(
        () => io.out.toString().contains(
          'skills: enabled create-goal (scope: project)',
        ),
      );
      expect(cli.systemPrompt, contains('<name>create-goal</name>'));
      expect(menuRow(cli, '/cre', '/create-goal'), isNotNull);
      io.sendLine('/exit');
      await run;
    },
  );

  test('AC4: global scope fires the host hook with the live toggles', () async {
    var persisted = 0;
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      onSkillTogglesChanged: () async => persisted++,
    );
    final run = cli.run();
    await waitForIt(
      () => cli.systemPrompt.contains('<name>self-settings</name>'),
    );
    io.sendLine('/skills off self-settings global');
    await waitForIt(
      () => io.out.toString().contains(
        'skills: disabled self-settings (scope: global)',
      ),
    );
    expect(persisted, 1);
    expect(cli.globalSkillToggles, {'self-settings': false});
    expect(cli.systemPrompt, isNot(contains('<name>self-settings</name>')));
    // Nothing was written to the project file for a global toggle.
    expect(
      (await env.readTextFile('/work/.fah/config.yaml')).valueOrNull,
      isNull,
    );
    io.sendLine('/exit');
    await run;
  });

  test(
    'AC4: global scope without a hook keeps the change for the session',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>create-goal</name>'),
      );
      io.sendLine('/skills off create-goal global');
      await waitForIt(() => io.out.toString().contains('no persistence hook'));
      expect(cli.systemPrompt, isNot(contains('<name>create-goal</name>')));
      io.sendLine('/exit');
      await run;
    },
  );

  test('AC4: the /settings hub carries a routed Skills row', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(
      () => cli.systemPrompt.contains('<name>create-goal</name>'),
    );
    final row = cli
        .settingsHubItemsForTest()
        .where((item) => item.key == 'skills')
        .single;
    expect(row.label, 'Skills');
    expect(row.description, '3 of 3 skills available');
    expect(cli.settingsPickerHandlerKeysForTest(), contains('skills'));
    // The line-mode summary shows the same live balance.
    io.sendLine('/settings');
    await waitForIt(
      () => io.out.toString().contains('skills: 3 of 3 skills available'),
    );
    io.sendLine('/exit');
    await run;
  });

  test(
    'AC5: builtin completion rows carry the (builtin) badge; project ones do not',
    () async {
      await env.writeFile(
        '/work/.fah/skills/ship/SKILL.md',
        '---\nname: ship\ndescription: Ship the app\n---\nbody\n',
      );
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>create-goal</name>'),
      );
      final goal = menuRow(cli, '/cre', '/create-goal');
      expect(goal, isNotNull);
      expect(goal!.description, contains('(builtin)'));
      // The project skill's row has no badge.
      io.sendLine('/skills reload');
      await waitForIt(() => io.out.toString().contains('reloaded: 4 skill(s)'));
      final ship = menuRow(cli, '/ship', '/ship');
      expect(ship, isNotNull);
      expect(ship!.description, isNot(contains('(builtin)')));
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'settings flow: enable/project, disable/global, then Done (AC4 hub arm)',
    () async {
      var globalPersisted = 0;
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        onSkillTogglesChanged: () async {
          globalPersisted++;
        },
      );
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>self-settings</name>'),
      );
      String out() => io.out.toString();

      final flow = cli.pickSettingForTest('skills');
      await waitForIt(() => out().contains('skills — pick a skill'));
      io.sendLine('1'); // create-goal
      await waitForIt(() => out().contains('skills — create-goal'));
      io.sendLine('1'); // Enable
      await waitForIt(() => out().contains('skills — enable create-goal in'));
      io.sendLine('1'); // Project
      await waitForIt(
        () => out().contains('skills: enabled create-goal (scope: project)'),
      );
      // The loop returns to the skill pick; disable the other builtin in
      // the global scope. (Name-ordered builtins: create-goal, js-apps,
      // self-settings — gh-1164 added the third.)
      io.sendLine('3'); // self-settings
      await waitForIt(() => out().contains('skills — self-settings'));
      io.sendLine('2'); // Disable
      await waitForIt(
        () => out().contains('skills — disable self-settings in'),
      );
      io.sendLine('2'); // Global
      await waitForIt(
        () => out().contains('skills: disabled self-settings (scope: global)'),
      );
      io.sendLine('4'); // Done
      await flow;

      // The project arm persisted the enable; the global arm fired the
      // host hook once.
      final file = (await env.readTextFile(
        '/work/.fah/config.yaml',
      )).valueOrNull;
      expect(file, contains('create-goal: true'));
      expect(globalPersisted, 1);
      // Same-session effect: self-settings is gone from the prompt.
      expect(cli.systemPrompt, isNot(contains('<name>self-settings</name>')));
      expect(cli.systemPrompt, contains('<name>create-goal</name>'));
      io.sendLine('/exit');
      await run;
    },
  );

  test('settings flow: cancel at each pick, invalid number re-prompts, Done '
      'ends (AC4 hub arm branches)', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(
      () => cli.systemPrompt.contains('<name>create-goal</name>'),
    );
    String out() => io.out.toString();

    // Cancel at the skill pick: the flow returns, nothing applied.
    var flow = cli.pickSettingForTest('skills');
    await waitForIt(() => out().contains('skills — pick a skill'));
    io.interrupt();
    await flow;
    expect(out(), isNot(contains('(scope:')));

    // Cancel at the action pick.
    flow = cli.pickSettingForTest('skills');
    await waitForIt(() => out().contains('skills — pick a skill'));
    io.sendLine('1'); // create-goal
    await waitForIt(() => out().contains('skills — create-goal'));
    io.interrupt();
    await flow;
    expect(out(), isNot(contains('(scope:')));

    // Cancel at the scope pick: the pick ran, nothing persisted.
    flow = cli.pickSettingForTest('skills');
    await waitForIt(() => out().contains('skills — pick a skill'));
    io.sendLine('1');
    await waitForIt(() => out().contains('skills — create-goal'));
    io.sendLine('1'); // Enable
    await waitForIt(() => out().contains('skills — enable create-goal in'));
    io.interrupt();
    await flow;
    expect(
      (await env.readTextFile('/work/.fah/config.yaml')).valueOrNull,
      isNull,
    );

    // A bad number re-prompts (and lists the options again), then Done
    // exits cleanly.
    flow = cli.pickSettingForTest('skills');
    await waitForIt(() => out().contains('skills — pick a skill'));
    io.sendLine('9');
    await waitForIt(() => out().contains('invalid selection: 9'));
    io.sendLine('4'); // Done
    await flow;
    // No pass completed: no toggle was ever applied or persisted.
    expect(out(), isNot(contains('(scope:')));
    io.sendLine('/exit');
    await run;
  });

  test(
    'merge seed parses every project-file shape (CRAP ladder, table)',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>create-goal</name>'),
      );
      String out() => io.out.toString();

      // One session, every file shape: (label, source to write or null for
      // an absent file, expected merge outcome — error substring or null
      // for success — and, on success, substrings the written body must
      // carry).
      final cases = <(String, String?, String?, List<String>?)>[
        ('absent file', null, null, ['skills:', 'create-goal: false']),
        ('blank file', '   \n', null, ['create-goal: false']),
        (
          'no skills key',
          'tools:\n  a: on\n',
          null,
          // The surgical rewrite preserved the outside-section key.
          ['tools:', '  a: on', 'create-goal: false'],
        ),
        (
          'section keys preserved',
          'top: keep\nskills:\n  access: ask\n'
              '  disableShellExecution: true\n  create-goal: on\n',
          null,
          [
            'top: keep',
            'access: ask',
            'disableShellExecution: true',
            'create-goal: false',
          ],
        ),
        // The raw yaml error text is engine-worded; the prefix assertion
        // below is the contract.
        ('broken yaml', 'skills: [unclosed\n', '', null),
        ('scalar doc', 'just a string\n', 'is not a map', null),
        ('scalar section', 'skills: 5\n', 'skills must be a map in', null),
        (
          'invalid value',
          'skills:\n  create-goal: yes-please\n',
          'skills.create-goal must be on/off',
          null,
        ),
      ];
      var successes = 0;
      var failures = 0;
      for (final (label, source, errorSub, expectInFile) in cases) {
        if (source != null) {
          await env.writeFile('/work/.fah/config.yaml', source);
        }
        io.sendLine('/skills off create-goal');
        if (errorSub == null) {
          // io.out is cumulative — wait for the count to move.
          await waitForIt(
            () =>
                'skills: disabled create-goal (scope: project)'
                    .allMatches(out())
                    .length >
                successes,
          );
          successes++;
          final body = (await env.readTextFile(
            '/work/.fah/config.yaml',
          )).valueOrNull!;
          for (final fragment in expectInFile!) {
            expect(body, contains(fragment), reason: label);
          }
          continue;
        }
        await waitForIt(
          () =>
              'skills: cannot merge project scope'.allMatches(out()).length >
              failures,
        );
        failures++;
        expect(out(), contains(errorSub), reason: label);
      }
      io.sendLine('/exit');
      await run;
    },
  );

  test('/skills caps a long description so one skill stays one terminal line '
      '(consent PTY suite #927 regressed on a 519-char builtin description '
      'wrapping greet off the 80x24 screen)', () async {
    await env.writeFile(
      '/work/.fah/skills/greet/SKILL.md',
      '---\nname: greet\ndescription: say hi\n---\nWave at the user.\n',
    );
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(
      () => cli.systemPrompt.contains('builtin://skills/create-goal'),
    );
    io.sendLine('/skills');
    await waitForIt(() => io.out.toString().contains('greet — say hi'));
    final listing = io.out
        .toString()
        .split('\n')
        .where((l) => l.contains('— '))
        .toList();
    // Every row keeps name + a capped description: the builtin's
    // model-facing text is cut (not absent), the project row is intact.
    final createGoal = listing.firstWhere((l) => l.contains('create-goal'));
    expect(createGoal, contains('Turn a feature idea'));
    // SGR-stripped: name + capped detail stay inside one 80-col line; the
    // dim tail may wrap as its own dim continuation (<= 2 lines total).
    final plainLine = createGoal.replaceAll(
      RegExp('\x1b\\[[0-9;?]*[ -/]*[@-~]'),
      '',
    );
    expect(plainLine.indexOf('  builtin://'), lessThan(80));
    expect(plainLine.length, lessThan(160));
    expect(listing.join('\n'), isNot(contains('cross-platform regression')));
    io.sendLine('/exit');
    await run;
  });
}

/// Issue #1151 AC8: the same assertions on the REAL TUI surface —
/// boot headlessly, script key bytes through TuiProgramHooks.input, and
/// read the rendered frames from TuiProgramHooks.output (the
/// agent_cli_tui_sync_test.dart pattern).
void tuiCompletionTests() {
  test(
    'AC8: TUI completion offers the builtin; disabling removes the row',
    () async {
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      final env = MemoryExecutionEnv(cwd: '/work');
      final io = FakeCliIO();
      final fake = FakeStreamFunction([textTurn('goal drafted')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          tuiProgramHooks: TuiProgramHooks(
            input: keys.stream,
            output: frames,
            // 600 cols so the long create-goal description (519 chars) and
            // its trailing badge are not truncated away in the overlay row.
            width: 600,
            height: 24,
          ),
        ),
        io: io,
        useTui: true,
        streamFunction: fake.call,
      );
      final run = cli.run();
      try {
        await waitForIt(() => frames.text.contains('\x1b[?1049h'));
        // Settle: keys sent during boot teardown of the welcome frame race
        // the program's input pump (a retried Enter lands fine; a fast one
        // can vanish) — the existing TUI tests pause before keystrokes too.
        Future<void> settle() =>
            Future<void>.delayed(const Duration(milliseconds: 250));
        await settle();
        // Type /cre: the completion overlay must offer the builtin WITH the
        // (builtin) badge in the rendered row.
        keys.add(utf8.encode('/cre'));
        await waitForIt(() => frames.plain.contains('(builtin)'));
        await settle();
        // Enter accepts the highlighted row into the composer…
        keys.add([0x0d]);
        await settle();
        // …and a second Enter submits it: the rendered builtin body runs.
        keys.add([0x0d]);
        await waitForIt(() => fake.calls == 1 && !cli.isBusy);
        // Toggle the builtin off through the same TUI.
        await settle();
        keys.add(utf8.encode('/skills off create-goal'));
        await settle();
        keys.add([0x0d]);
        await waitForIt(() => frames.plain.contains('disabled create-goal'));
        // The completion row is gone from the freshly rendered frames.
        await settle();
        final before = frames.plain.length;
        keys.add(utf8.encode('/cre'));
        await waitForIt(() => frames.plain.substring(before).contains('/cre'));
        // One settle so any overlay render would have landed, then assert.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(frames.plain.substring(before), isNot(contains('/create-goal')));
        keys.add([0x03]); // ctrl+c press 1: arms the double-press window
        keys.add([0x03]); // press 2 within the window quits the TUI
        await run;
      } finally {
        await keys.close();
        await io.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// Collects rendered frame bytes (dart_tui wraps this into an IOSink).
class _FrameSink implements StreamConsumer<List<int>> {
  final _bytes = BytesBuilder(copy: false);

  // Plain members: IOSink invokes them through the runtime instance, but
  // they are not part of the StreamConsumer interface.
  void add(List<int> data) => _bytes.add(data);

  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  String get text => utf8.decode(_bytes.toBytes(), allowMalformed: true);

  /// The frames with SGR/CSI escape runs stripped — fuzzy-highlighted
  /// labels embed per-rune SGR, so literal substring checks must run on
  /// the visible text only.
  String get plain => text.replaceAll(RegExp('\x1b\\[[0-9;?]*[ -/]*[@-~]'), '');
}
