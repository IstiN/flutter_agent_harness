// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/skills_toggles_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/screens/skills_toggles_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

AgentConfig _config() => AgentConfig(
  providerKind: 'openai-completions',
  modelId: 'test-model',
  baseUrl: 'https://example.test',
  apiKey: 'test-key',
);

/// A project skill shadowing the builtin `create-goal` name, with its own
/// distinctive description marker.
Future<void> _seedShadowingSkill(ExecutionEnv env) async {
  await env.writeFile(
    '${env.cwd}/.fah/skills/create-goal/SKILL.md',
    '---\nname: create-goal\ndescription: PROJECT SHADOW MARKER\n---\nBody\n',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SkillsTogglesStore', () {
    test('missing file loads as {} (every skill default-on)', () async {
      final env = MemoryExecutionEnv();
      expect(await SkillsTogglesStore(env).load(), isEmpty);
    });

    test('the toggles round-trip through the env filesystem', () async {
      final env = MemoryExecutionEnv();
      final store = SkillsTogglesStore(env);
      await store.save(const {'create-goal': false, 'self-settings': true});

      expect(await store.load(), {'create-goal': false, 'self-settings': true});
      // The documented envelope shape.
      final decoded =
          jsonDecode(
                (await env.readTextFile(
                  '${env.cwd}/skills_toggles.json',
                )).valueOrNull!,
              )
              as Map<String, dynamic>;
      expect(decoded['version'], 1);
      expect(decoded['toggles'], {'create-goal': false, 'self-settings': true});
    });

    test('a corrupt file loads as {} instead of crashing', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/skills_toggles.json', '{not json');
      expect(await SkillsTogglesStore(env).load(), isEmpty);
    });

    test('a wrong schema version loads as {}', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/skills_toggles.json',
        jsonEncode({
          'version': 99,
          'toggles': {'create-goal': false},
        }),
      );
      expect(await SkillsTogglesStore(env).load(), isEmpty);
    });

    test('non-boolean entries are dropped, not fatal', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/skills_toggles.json',
        jsonEncode({
          'version': 1,
          'toggles': {'create-goal': false, 'junk': 'off'},
        }),
      );
      expect(await SkillsTogglesStore(env).load(), {'create-goal': false});
    });
  });

  group('AgentService builtin skill discovery (issue #1151 AC6)', () {
    test('upgrade path: stale app-seeded copies are removed at boot, '
        'customized overrides stay (issue #1151 review CQE1)', () async {
      final env = MemoryExecutionEnv();
      // What earlier app versions wrote for create-goal: the LAST
      // SEEDED bytes (the repo's .fah/skills copy at the time — the
      // drift guard pinned assets byte-identical to it; the builtin
      // port tweaked two sentences, so this copy carries the OLD
      // description). fa-self-config names a retired skill.
      final stale = await File(
        '../.fah/skills/create-goal/SKILL.md',
      ).readAsString();
      await env.writeFile('${env.cwd}/.fah/skills/create-goal/SKILL.md', stale);
      final orphan = await File(
        '../.fah/skills/fa-self-config/SKILL.md',
      ).readAsString();
      await env.writeFile(
        '${env.cwd}/.fah/skills/fa-self-config/SKILL.md',
        orphan,
      );
      // A deliberate project override: different bytes, user-owned.
      await env.writeFile(
        '${env.cwd}/.fah/skills/self-settings/SKILL.md',
        '---\nname: self-settings\ndescription: PROJECT OVERRIDE MARKER\n---\nBody\n',
      );
      // A user-dropped supporting file next to a stale seed survives —
      // only SKILL.md goes (review -HUjo); the seeder never wrote it.
      await env.writeFile(
        '${env.cwd}/.fah/skills/create-goal/notes.md',
        'user notes',
      );
      final service = await AgentService.create(config: _config(), env: env);
      addTearDown(service.dispose);

      // Both stale seeds are gone: create-goal no longer shadows the
      // compiled-in builtin, fa-self-config is not listed at all.
      expect(
        (await env.readTextFile(
          '${env.cwd}/.fah/skills/create-goal/SKILL.md',
        )).valueOrNull,
        isNull,
      );
      expect(
        (await env.readTextFile(
          '${env.cwd}/.fah/skills/fa-self-config/SKILL.md',
        )).valueOrNull,
        isNull,
      );
      // The user-dropped supporting file next to the stale create-goal
      // seed survived the cleanup (only SKILL.md goes, review -HUjo).
      expect(
        (await env.readTextFile(
          '${env.cwd}/.fah/skills/create-goal/notes.md',
        )).valueOrNull,
        'user notes',
      );
      final prompt = service.systemPromptForTest;
      expect(prompt, contains('PROJECT OVERRIDE MARKER'));
      expect('<name>create-goal</name>'.allMatches(prompt), hasLength(1));
      expect(
        prompt,
        contains('<location>builtin://skills/create-goal/SKILL.md</location>'),
      );
      expect(prompt, isNot(contains('fa-self-config')));
    });

    test('a fresh env resolves the builtins without any seeded copy', () async {
      final env = MemoryExecutionEnv();
      final service = await AgentService.create(config: _config(), env: env);
      addTearDown(service.dispose);

      // The app no longer seeds the package builtins into .fah/skills.
      expect(
        (await env.readTextFile(
          '${env.cwd}/.fah/skills/create-goal/SKILL.md',
        )).valueOrNull,
        isNull,
      );
      expect(
        (await env.readTextFile(
          '${env.cwd}/.fah/skills/fa-self-config/SKILL.md',
        )).valueOrNull,
        isNull,
      );
      // gh-1164 Part A: js-apps moved into the package builtins — the app
      // seeds nothing anymore (the seeder only retires stale copies).
      expect(
        (await env.readTextFile(
          '${env.cwd}/.fah/skills/js-apps/SKILL.md',
        )).valueOrNull,
        isNull,
      );

      // The prompt lists both builtins from the package — exactly once
      // each, at their builtin:// locations (the chat invocation path:
      // the model reads the listed file, the read tool serves the
      // embedded copy).
      final prompt = service.systemPromptForTest;
      expect('<name>create-goal</name>'.allMatches(prompt), hasLength(1));
      expect('<name>self-settings</name>'.allMatches(prompt), hasLength(1));
      expect(
        prompt,
        contains('<location>builtin://skills/create-goal/SKILL.md</location>'),
      );
      expect(prompt, contains('<name>js-apps</name>'));
      expect(
        prompt,
        contains('<location>builtin://skills/js-apps/SKILL.md</location>'),
      );
      expect(service.isSkillEnabled('create-goal'), isTrue);
    });

    test('a project skill of the same name shadows the builtin (no '
        'duplicate listing)', () async {
      final env = MemoryExecutionEnv();
      await _seedShadowingSkill(env);
      final service = await AgentService.create(config: _config(), env: env);
      addTearDown(service.dispose);

      final prompt = service.systemPromptForTest;
      expect('<name>create-goal</name>'.allMatches(prompt), hasLength(1));
      expect(prompt, contains('PROJECT SHADOW MARKER'));
      expect(prompt, isNot(contains('builtin://skills/create-goal')));
    });

    test(
      'a persisted toggle-off keeps the builtin out of the prompt',
      () async {
        final env = MemoryExecutionEnv();
        await SkillsTogglesStore(
          env,
        ).save(const {'create-goal': false, 'self-settings': false});
        final service = await AgentService.create(config: _config(), env: env);
        addTearDown(service.dispose);

        final prompt = service.systemPromptForTest;
        expect(prompt, isNot(contains('<name>create-goal</name>')));
        expect(prompt, isNot(contains('<name>self-settings</name>')));
        expect(service.isSkillEnabled('create-goal'), isFalse);
        // js-apps is a builtin too — unaffected by these two toggles.
        expect(prompt, contains('<name>js-apps</name>'));
      },
    );

    test('setSkillToggle re-discovers live and persists the choice', () async {
      final env = MemoryExecutionEnv();
      final service = await AgentService.create(config: _config(), env: env);
      addTearDown(service.dispose);
      expect(service.systemPromptForTest, contains('<name>create-goal</name>'));

      await service.setSkillToggle('create-goal', false);
      expect(
        service.systemPromptForTest,
        isNot(contains('<name>create-goal</name>')),
      );
      expect(
        service.systemPromptForTest,
        contains('<name>self-settings</name>'),
      );
      expect(await SkillsTogglesStore(env).load(), {'create-goal': false});

      await service.setSkillToggle('create-goal', true);
      expect(service.systemPromptForTest, contains('<name>create-goal</name>'));
      expect(await SkillsTogglesStore(env).load(), {'create-goal': true});
    });

    test(
      'toggling an unknown skill persists without breaking discovery',
      () async {
        final env = MemoryExecutionEnv();
        final service = await AgentService.create(config: _config(), env: env);
        addTearDown(service.dispose);

        // resolveSkillAvailability collects unknown ids non-fatally; the
        // prompt is recomposed unchanged.
        await service.setSkillToggle('no-such-skill', false);
        expect(service.isSkillEnabled('no-such-skill'), isFalse);
        expect(
          service.systemPromptForTest,
          contains('<name>create-goal</name>'),
        );
      },
    );

    test(
      'clone() inherits the current toggles, not a fresh disk read',
      () async {
        final env = MemoryExecutionEnv();
        final service = await AgentService.create(config: _config(), env: env);
        addTearDown(service.dispose);
        await service.setSkillToggle('create-goal', false);
        // Wipe the persisted value: a fresh read would re-enable the skill.
        await env.writeFile('${env.cwd}/skills_toggles.json', '{}');

        final clone = service.clone();
        addTearDown(clone.dispose);
        expect(clone.isSkillEnabled('create-goal'), isFalse);
        expect(
          clone.systemPromptForTest,
          isNot(contains('<name>create-goal</name>')),
        );
      },
    );
  });

  group('SkillsTogglesSection (settings)', () {
    Future<(AgentService, MemoryExecutionEnv)> pumpSection(
      WidgetTester tester,
    ) async {
      final env = MemoryExecutionEnv();
      // AgentService.create waits out a 5 s timeout around the bundled-skill
      // asset load, and that clock never advances inside the fake test zone
      // (same trap as skills_access_store_test) — create in a real-async
      // window.
      late final AgentService service;
      await tester.runAsync(() async {
        service = await AgentService.create(config: _config(), env: env);
      });
      addTearDown(service.dispose);

      // Bounded pumps, never pumpAndSettle: the service's periodic inbox
      // watcher keeps scheduling frames in fake time, so pumpAndSettle
      // would loop until the test timeout.
      Future<void> pumpN([int n = 10]) async {
        for (var i = 0; i < n; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SkillsTogglesSection(service: service)),
        ),
      );
      await pumpN();
      return (service, env);
    }

    Finder row(String name) => find.ancestor(
      of: find.text(name),
      matching: find.byType(SwitchListTile),
    );

    testWidgets('renders one default-on switch per package builtin', (
      tester,
    ) async {
      await pumpSection(tester);

      final builtins = builtinSkills();
      expect(
        builtins.map((s) => s.name),
        containsAll(['create-goal', 'self-settings']),
      );
      expect(find.byType(SwitchListTile), findsNWidgets(builtins.length));
      for (final skill in builtins) {
        expect(tester.widget<SwitchListTile>(row(skill.name)).value, isTrue);
        // One-line description under the name.
        expect(find.textContaining(skill.description), findsOneWidget);
      }
    });

    testWidgets('flipping a row re-discovers live and persists', (
      tester,
    ) async {
      final (service, env) = await pumpSection(tester);
      expect(service.systemPromptForTest, contains('<name>create-goal</name>'));

      await tester.tap(row('create-goal'));
      // setSkillToggle persists and re-discovers on real futures — give
      // them a real-async window before asserting.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(tester.widget<SwitchListTile>(row('create-goal')).value, isFalse);
      expect(
        service.systemPromptForTest,
        isNot(contains('<name>create-goal</name>')),
      );
      expect(await SkillsTogglesStore(env).load(), {'create-goal': false});
    });
  });
}
