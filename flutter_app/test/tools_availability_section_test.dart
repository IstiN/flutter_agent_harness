// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/tools_availability_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/tools_availability_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

AgentConfig _config() => AgentConfig(
  providerKind: 'openai-completions',
  modelId: 'test-model',
  baseUrl: 'https://example.test',
  apiKey: 'test-key',
);

Future<AgentService> _createService([ExecutionEnv? env]) async {
  final service = await AgentService.create(
    config: _config(),
    env: env ?? MemoryExecutionEnv(),
  );
  return service;
}

Finder _row(String id) =>
    find.ancestor(of: find.text(id), matching: find.byType(SwitchListTile));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AgentService tools availability', () {
    test(
      'wired capabilities default on; unwired ids report a reason',
      () async {
        final service = await _createService();
        addTearDown(service.dispose);

        final availability = service.toolAvailability;
        expect(availability.keys.toSet(), knownToolIds);

        // Actually wired on this (host) config: present + enabled.
        for (final id in ['read', 'write', 'edit', 'ls', 'bash', 'bash_job']) {
          expect(availability[id]!.capabilityPresent, isTrue, reason: id);
          expect(availability[id]!.enabled, isTrue, reason: id);
        }
        for (final id in [
          'memory',
          'ask',
          'request_secret',
          'task',
          'schedule_message',
          'web_search',
          'generate_image',
          'generate_video',
          'transcribe_audio',
        ]) {
          expect(availability[id]!.capabilityPresent, isTrue, reason: id);
        }

        // Structurally absent in the app sandbox, each with its reason.
        expect(availability['sqlite']!.capabilityPresent, isFalse);
        expect(availability['sqlite']!.reason, contains('SQLite'));
        expect(availability['lsp']!.capabilityPresent, isFalse);
        expect(availability['mcp']!.capabilityPresent, isFalse);
        expect(availability['dap']!.capabilityPresent, isFalse);
        expect(availability['checkpoint']!.capabilityPresent, isFalse);
        expect(availability['rewind']!.capabilityPresent, isFalse);
        expect(availability['inspect_image']!.capabilityPresent, isFalse);
      },
    );

    test(
      'setToolEnabled hides the tool live and persists the choice',
      () async {
        final env = MemoryExecutionEnv();
        final service = await _createService(env);
        addTearDown(service.dispose);
        expect(service.toolsForTest.map((tool) => tool.name), contains('bash'));

        await service.setToolEnabled('bash', false);
        expect(
          service.toolsForTest.map((tool) => tool.name),
          isNot(contains('bash')),
        );
        expect(service.toolAvailability['bash']!.enabled, isFalse);
        expect(
          (await ToolsAvailabilityStore(env).load())?.tools['bash'],
          isFalse,
        );
        // The live prompt is recomposed without a restart.
        expect(service.systemPromptForTest, isNotEmpty);

        await service.setToolEnabled('bash', true);
        expect(service.toolsForTest.map((tool) => tool.name), contains('bash'));
      },
    );

    test('an absent capability stays off no matter what config asks', () async {
      final service = await _createService();
      addTearDown(service.dispose);

      await service.setToolEnabled('sqlite', true);
      expect(service.toolAvailability['sqlite']!.enabled, isFalse);
      expect(
        service.toolsForTest.map((tool) => tool.name),
        isNot(contains('sqlite')),
      );
    });

    test('a persisted config seeds the session at boot', () async {
      final env = MemoryExecutionEnv();
      await ToolsAvailabilityStore(
        env,
      ).save(ToolsConfig(tools: {'bash': false, 'web_search': false}));

      final service = await _createService(env);
      addTearDown(service.dispose);

      final names = service.toolsForTest.map((tool) => tool.name);
      expect(names, isNot(contains('bash')));
      expect(names, isNot(contains('web_search')));
      // web_search is a FAMILY id: hiding it hides web_fetch too.
      expect(names, isNot(contains('web_fetch')));
      expect(names, contains('write'));
    });

    test(
      'clone() inherits the current tools config, not a fresh disk read',
      () async {
        final env = MemoryExecutionEnv();
        final service = await _createService(env);
        addTearDown(service.dispose);
        await service.setToolEnabled('bash', false);
        // Wipe the persisted value: a fresh read would re-enable the tool.
        await env.writeFile('${env.cwd}/tools_availability.json', '{}');

        final clone = service.clone();
        addTearDown(clone.dispose);
        expect(clone.toolAvailability['bash']!.enabled, isFalse);
      },
    );
  });

  group('ToolsAvailabilitySection (settings)', () {
    testWidgets('renders one row per known tool id with live switch state', (
      tester,
    ) async {
      late final AgentService service;
      await tester.runAsync(() async {
        service = await _createService();
      });
      addTearDown(service.dispose);

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
          home: Scaffold(
            body: SingleChildScrollView(
              child: ToolsAvailabilitySection(service: service),
            ),
          ),
        ),
      );
      await pumpN();

      expect(find.byType(SwitchListTile), findsNWidgets(knownToolIds.length));

      // A wired tool: switch on and interactive.
      final bashRow = tester.widget<SwitchListTile>(_row('bash'));
      expect(bashRow.value, isTrue);
      expect(bashRow.onChanged, isNotNull);

      // An absent capability: switch off, disabled, with its reason shown.
      final sqliteRow = tester.widget<SwitchListTile>(_row('sqlite'));
      expect(sqliteRow.value, isFalse);
      expect(sqliteRow.onChanged, isNull);
      expect(find.textContaining('FFI SQLite engine'), findsOneWidget);
    });

    testWidgets('toggling a row hides the tool live', (tester) async {
      final env = MemoryExecutionEnv();
      late final AgentService service;
      await tester.runAsync(() async {
        service = await _createService(env);
      });
      addTearDown(service.dispose);

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
          home: Scaffold(
            body: SingleChildScrollView(
              child: ToolsAvailabilitySection(service: service),
            ),
          ),
        ),
      );
      await pumpN();

      await tester.tap(_row('bash'));
      // setToolEnabled persists on real futures — give them a real-async
      // window before asserting.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await pumpN();

      expect(
        service.toolsForTest.map((tool) => tool.name),
        isNot(contains('bash')),
      );
      expect(tester.widget<SwitchListTile>(_row('bash')).value, isFalse);
      expect(
        (await ToolsAvailabilityStore(env).load())?.tools['bash'],
        isFalse,
      );
    });
  });
}
