// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/skills_access_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

AgentConfig _config() => AgentConfig(
  providerKind: 'openai-completions',
  modelId: 'test-model',
  baseUrl: 'https://example.test',
  apiKey: 'test-key',
);

/// A minimal third-party (Claude) + first-party skill pair on the env fs.
Future<void> _seedSkills(ExecutionEnv env) async {
  await env.writeFile(
    '${env.cwd}/.claude/skills/deploy/SKILL.md',
    '---\nname: thirdparty-deploy\ndescription: Deploy things\n---\nBody\n',
  );
  await env.writeFile(
    '${env.cwd}/.fah/skills/own/SKILL.md',
    '---\nname: firstparty-own\ndescription: Own skill\n---\nBody\n',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SkillsAccessStore', () {
    test('missing file loads as null (undecided)', () async {
      final env = MemoryExecutionEnv();
      expect(await SkillsAccessStore(env).load(), isNull);
    });

    test('corrupt file loads as null instead of crashing', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/skills_access.json', 'not json {');
      expect(await SkillsAccessStore(env).load(), isNull);
    });

    test('a wrong schema version loads as null', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/skills_access.json',
        '{"version": 99, "access": "granted"}',
      );
      expect(await SkillsAccessStore(env).load(), isNull);
    });

    test('a persisted "ask" label loads as null (undecided)', () async {
      final env = MemoryExecutionEnv();
      await SkillsAccessStore(env).save(SkillsAccess.ask);
      expect(await SkillsAccessStore(env).load(), isNull);
    });

    test('the consent round-trips through the env filesystem', () async {
      final env = MemoryExecutionEnv();
      final store = SkillsAccessStore(env);
      await store.save(SkillsAccess.granted);
      expect(await SkillsAccessStore(env).load(), SkillsAccess.granted);

      await store.save(SkillsAccess.denied);
      expect(await SkillsAccessStore(env).load(), SkillsAccess.denied);
    });
  });

  group('AgentService skills access', () {
    test('undecided consent discovers only first-party skills', () async {
      final env = MemoryExecutionEnv();
      await _seedSkills(env);
      final service = await AgentService.create(config: _config(), env: env);
      addTearDown(service.dispose);

      expect(service.skillsAccess, SkillsAccess.ask);
      expect(service.systemPromptForTest, contains('firstparty-own'));
      expect(service.systemPromptForTest, isNot(contains('thirdparty-deploy')));
    });

    test('denied consent discovers only first-party skills', () async {
      final env = MemoryExecutionEnv();
      await _seedSkills(env);
      await SkillsAccessStore(env).save(SkillsAccess.denied);
      final service = await AgentService.create(config: _config(), env: env);
      addTearDown(service.dispose);

      expect(service.skillsAccess, SkillsAccess.denied);
      expect(service.systemPromptForTest, isNot(contains('thirdparty-deploy')));
    });

    test('granted consent discovers third-party skills too', () async {
      final env = MemoryExecutionEnv();
      await _seedSkills(env);
      await SkillsAccessStore(env).save(SkillsAccess.granted);
      final service = await AgentService.create(config: _config(), env: env);
      addTearDown(service.dispose);

      expect(service.skillsAccess, SkillsAccess.granted);
      expect(service.systemPromptForTest, contains('thirdparty-deploy'));
    });

    test('setSkillsAccess re-discovers live and persists the choice', () async {
      final env = MemoryExecutionEnv();
      await _seedSkills(env);
      final service = await AgentService.create(config: _config(), env: env);
      addTearDown(service.dispose);
      expect(service.systemPromptForTest, isNot(contains('thirdparty-deploy')));

      await service.setSkillsAccess(SkillsAccess.granted);
      expect(service.systemPromptForTest, contains('thirdparty-deploy'));
      expect(await SkillsAccessStore(env).load(), SkillsAccess.granted);

      await service.setSkillsAccess(SkillsAccess.denied);
      expect(service.systemPromptForTest, isNot(contains('thirdparty-deploy')));
      expect(await SkillsAccessStore(env).load(), SkillsAccess.denied);
    });

    test(
      'clone() inherits the current consent, not a fresh disk read',
      () async {
        final env = MemoryExecutionEnv();
        final service = await AgentService.create(config: _config(), env: env);
        addTearDown(service.dispose);
        await service.setSkillsAccess(SkillsAccess.granted);
        // Wipe the persisted value: a fresh read would be undecided.
        await env.writeFile('${env.cwd}/skills_access.json', '{}');

        final clone = service.clone();
        addTearDown(clone.dispose);
        expect(clone.skillsAccess, SkillsAccess.granted);
      },
    );
  });

  group('SkillsAccessSection (settings)', () {
    testWidgets('the dropdown reflects and changes the consent', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      await _seedSkills(env);
      // AgentService.create waits out a 5 s timeout around the bundled-skill
      // asset load, and that clock never advances inside the fake test zone
      // (same trap as boot_flows_test) — create in a real-async window.
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
          home: Scaffold(body: SkillsAccessSection(service: service)),
        ),
      );
      await pumpN();
      expect(find.text('Skills access'), findsOneWidget);
      expect(find.text('Ask'), findsOneWidget); // undecided by default

      await tester.tap(find.byType(DropdownButton<SkillsAccess>));
      await pumpN();
      await tester.tap(find.text('Allowed').last);
      // setSkillsAccess re-discovers and persists on real futures — give
      // them a real-async window before asserting.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await pumpN();

      expect(service.skillsAccess, SkillsAccess.granted);
      expect(await SkillsAccessStore(env).load(), SkillsAccess.granted);
      // The consent re-discovered third-party skills into the prompt.
      expect(service.systemPromptForTest, contains('thirdparty-deploy'));
    });
  });
}
