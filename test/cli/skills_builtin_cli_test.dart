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
    expect(row.description, '2 of 2 skills available');
    expect(cli.settingsPickerHandlerKeysForTest(), contains('skills'));
    // The line-mode summary shows the same live balance.
    io.sendLine('/settings');
    await waitForIt(
      () => io.out.toString().contains('skills: 2 of 2 skills available'),
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
      await waitForIt(() => io.out.toString().contains('reloaded: 3 skill(s)'));
      final ship = menuRow(cli, '/ship', '/ship');
      expect(ship, isNotNull);
      expect(ship!.description, isNot(contains('(builtin)')));
      io.sendLine('/exit');
      await run;
    },
  );
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
