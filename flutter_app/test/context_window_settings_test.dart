// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2479 — the context-window settings sections:
/// - the per-model row shows the effective window + source layer and the
///   cap note; Save persists through the seams and applies live; invalid
///   and below-floor values are refused with a verbatim message;
/// - the owner-cap control shows the effective cap + config layer; a
///   fresh choice writes the project layer (the compaction rule), a
///   user-sourced choice edits in place; Clear removes the key;
/// - the web stub renders the not-configurable note on both.
library;

import 'dart:async' show Completer;
import 'dart:io' as io;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/context_window_config.dart';
import 'package:fa/ui/screens/context_window_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';

AgentService _service(io.Directory tmp) => AgentService(
  agent: Agent(
    model: const Model(
      id: 'big',
      api: 'openai-completions',
      provider: 'aiin',
      baseUrl: 'https://aiin.example/v1',
      contextWindow: 200000,
      maxTokens: 16384,
    ),
    systemPrompt: 'You are Fa.',
    streamFunction: (model, context, {cancelToken}) {
      final stream = AssistantMessageEventStream();
      stream.end();
      return stream;
    },
    toolRegistry: ToolRegistry(const []),
  ),
  env: LocalExecutionEnv(cwd: tmp.path),
  sessionsRoot: tmp.path,
  watchExternalSessions: false,
  includeSharedSessionRoots: false,
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pump();
}

void main() {
  late io.Directory tmp;

  setUp(() async {
    tmp = await io.Directory.systemTemp.createTemp('fa_ctx2479ui_');
    modelCapabilityOverrides = null;
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('ModelContextWindowSection', () {
    testWidgets('shows the effective window and its source layer', (
      tester,
    ) async {
      final service = _service(tmp);
      await service.reconfigure(
        AgentConfig(
          providerKind: 'aiin',
          modelId: 'big',
          baseUrl: 'https://aiin.example/v1',
          apiKey: '',
          contextWindow: 1048576,
          maxTokens: 16384,
        ),
      );
      await _pump(
        tester,
        ModelContextWindowSection(service: service, readOverride: () => null),
      );
      expect(find.text('Context window'), findsOneWidget);
      expect(
        find.textContaining('1,048,576'),
        findsOneWidget,
        reason: 'the effective window renders in the grouped form',
      );
      expect(
        find.textContaining('1,048,576 · endpoint report'),
        findsOneWidget,
        reason: 'the caption names the chain layer that won',
      );
    });

    testWidgets('a pin shows the override source; Save persists and applies', (
      tester,
    ) async {
      final service = _service(tmp);
      await service.reconfigure(
        AgentConfig(
          providerKind: 'aiin',
          modelId: 'big',
          baseUrl: 'https://aiin.example/v1',
          apiKey: '',
          contextWindow: 1048576,
          maxTokens: 16384,
        ),
      );
      final writes = <(String, String, int?)>[];
      int? pinned = 200000;
      // The layer the fake write "persists" — handed to the apply seam
      // the way the real user-config write hands it to the reload.
      ModelCapabilityOverrides? layer;
      await _pump(
        tester,
        ModelContextWindowSection(
          service: service,
          readOverride: () => pinned,
          readLayer: () => layer,
          write: (provider, modelId, value) async {
            writes.add((provider, modelId, value));
            pinned = value;
            layer = value == null
                ? ModelCapabilityOverrides()
                : (ModelCapabilityOverrides()..set(
                    provider,
                    modelId,
                    ModelCapabilityOverride(contextWindow: value),
                  ));
            return '/home/.fah/config.yaml';
          },
        ),
      );
      // The seeded field carries the pin; the provenance caption still
      // names the chain layer until the override is applied.
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('contextWindowOverrideField')),
      );
      expect(field.controller!.text, '200000');
      await tester.enterText(
        find.byKey(const ValueKey('contextWindowOverrideField')),
        '131072',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(writes, [
        ('aiin', 'big', 131072),
      ], reason: 'the SAME config key the CLI pins (user scope)');
      expect(service.agentModel.contextWindow, 131072, reason: 'live apply');
      expect(
        service.modelContextWindow!.source,
        CapabilityWindowLayer.override,
      );
      await tester.pump();
      expect(
        find.textContaining('131,072 · override'),
        findsOneWidget,
        reason: 'the applied override becomes the caption layer',
      );
      expect(find.textContaining('Saved to'), findsOneWidget);
    });

    testWidgets('an empty override clears the pin and restores the chain', (
      tester,
    ) async {
      final service = _service(tmp);
      await service.reconfigure(
        AgentConfig(
          providerKind: 'aiin',
          modelId: 'big',
          baseUrl: 'https://aiin.example/v1',
          apiKey: '',
          contextWindow: 1048576,
          maxTokens: 16384,
        ),
      );
      final pinned = 200000;
      await _pump(
        tester,
        ModelContextWindowSection(
          service: service,
          readOverride: () => pinned,
          write: (provider, modelId, value) async {
            modelCapabilityOverrides = value == null
                ? ModelCapabilityOverrides()
                : (ModelCapabilityOverrides()..set(
                    'aiin',
                    'big',
                    ModelCapabilityOverride(contextWindow: value),
                  ));
            return '/home/.fah/config.yaml';
          },
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('contextWindowOverrideField')),
        '',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(service.agentModel.contextWindow, 1048576);
      expect(
        service.modelContextWindow!.source,
        CapabilityWindowLayer.endpoint,
      );
      expect(find.textContaining('Override cleared'), findsOneWidget);
    });

    testWidgets('a below-floor value is refused with the floor message', (
      tester,
    ) async {
      final service = _service(tmp);
      await service.reconfigure(
        AgentConfig(
          providerKind: 'aiin',
          modelId: 'big',
          baseUrl: 'https://aiin.example/v1',
          apiKey: '',
          contextWindow: 1048576,
          maxTokens: 16384,
        ),
      );
      var wrote = false;
      await _pump(
        tester,
        ModelContextWindowSection(
          service: service,
          readOverride: () => null,
          write: (_, _, _) async {
            wrote = true;
            return '/x';
          },
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('contextWindowOverrideField')),
        '1024',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(wrote, isFalse, reason: 'the refused write persists nothing');
      expect(find.textContaining('Minimum 16384 tokens'), findsOneWidget);
    });

    testWidgets('web: the not-configurable note replaces the controls', (
      tester,
    ) async {
      final service = _service(tmp);
      await service.reconfigure(
        AgentConfig(
          providerKind: 'aiin',
          modelId: 'big',
          baseUrl: 'https://aiin.example/v1',
          apiKey: '',
          contextWindow: 1048576,
          maxTokens: 16384,
        ),
      );
      await _pump(
        tester,
        ModelContextWindowSection(service: service, supported: false),
      );
      expect(
        find.byKey(const ValueKey('contextWindowOverrideField')),
        findsNothing,
      );
      expect(find.textContaining('Not configurable'), findsOneWidget);
    });
  });

  group('ContextWindowCapSection', () {
    testWidgets('shows the effective cap and its config layer', (tester) async {
      await _pump(
        tester,
        ContextWindowCapSection(
          resolve: ({projectDir, homeDir}) =>
              const AppContextCapResolution(65536, AppContextCapSource.user),
        ),
      );
      expect(find.text('Context window cap'), findsOneWidget);
      expect(
        find.textContaining('user ~/.fah/config.yaml'),
        findsOneWidget,
        reason: 'the source layer is shown like the compaction picker',
      );
      expect(
        find.textContaining('compaction thresholds'),
        findsOneWidget,
        reason: 'the semantics helper documents what the cap clamps',
      );
    });

    testWidgets('an unset cap shows the unset caption and no Clear button', (
      tester,
    ) async {
      await _pump(
        tester,
        ContextWindowCapSection(
          resolve: ({projectDir, homeDir}) =>
              const AppContextCapResolution(null, AppContextCapSource.none),
        ),
      );
      // The unset caption renders twice: the empty-field hint and the
      // source caption under it.
      expect(find.textContaining('Not set'), findsNWidgets(2));
      expect(find.text('Clear cap'), findsNothing);
    });

    testWidgets('a user-sourced cap is edited on the user layer', (
      tester,
    ) async {
      final writes = <(int?, AppContextCapSource)>[];
      await _pump(
        tester,
        ContextWindowCapSection(
          resolve: ({projectDir, homeDir}) =>
              const AppContextCapResolution(65536, AppContextCapSource.user),
          write: (value, {required layer, projectDir, homeDir}) async {
            writes.add((value, layer));
            return '/home/.fah/config.yaml';
          },
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('contextWindowCapField')),
        '32768',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(writes, [
        (32768, AppContextCapSource.user),
      ], reason: 'the layer that currently wins is edited in place');
    });

    testWidgets('a fresh choice writes the project layer when a dir exists', (
      tester,
    ) async {
      final writes = <(int?, AppContextCapSource)>[];
      await _pump(
        tester,
        ContextWindowCapSection(
          projectDir: '/proj',
          resolve: ({projectDir, homeDir}) =>
              const AppContextCapResolution(null, AppContextCapSource.none),
          write: (value, {required layer, projectDir, homeDir}) async {
            writes.add((value, layer));
            return '/proj/.fah/config.yaml';
          },
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('contextWindowCapField')),
        '200000',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(writes, [(200000, AppContextCapSource.project)]);
    });

    testWidgets(
      'Save with an empty field clears the cap; the apply seam fires',
      (tester) async {
        final writes = <int?>[];
        final applied = <int?>[];
        await _pump(
          tester,
          ContextWindowCapSection(
            resolve: ({projectDir, homeDir}) =>
                const AppContextCapResolution(65536, AppContextCapSource.user),
            write: (value, {required layer, projectDir, homeDir}) async {
              writes.add(value);
              return '/home/.fah/config.yaml';
            },
            apply: applied.add,
          ),
        );
        await tester.tap(find.text('Clear cap'));
        await tester.pump();
        expect(writes, [null]);
        expect(applied, [null], reason: 'the live re-cap runs after the write');
      },
    );

    testWidgets('a save in flight blocks re-entry (the sibling pattern)', (
      tester,
    ) async {
      // gh-2479 review: a Save/Clear double-tap used to fire two
      // concurrent read-modify-write edits of config.yaml. The in-flight
      // gate (the per-model section's _busy pattern) must let exactly
      // one write through.
      final gate = Completer<void>();
      var firstWriteStarted = false;
      final writes = <int?>[];
      await _pump(
        tester,
        ContextWindowCapSection(
          resolve: ({projectDir, homeDir}) =>
              const AppContextCapResolution(65536, AppContextCapSource.user),
          write: (value, {required layer, projectDir, homeDir}) async {
            if (!firstWriteStarted) {
              firstWriteStarted = true;
              writes.add(value);
              await gate.future;
              return '/home/.fah/config.yaml';
            }
            writes.add(value);
            return '/home/.fah/config.yaml';
          },
        ),
      );
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(firstWriteStarted, isTrue, reason: 'the first save is in flight');
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.tap(find.text('Clear cap'));
      await tester.pump();
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(writes, [
        65536,
      ], reason: 'the double-tap fired one read-modify-write, not two');
    });

    testWidgets('a saved cap refreshes the caption without an ancestor pump', (
      tester,
    ) async {
      // gh-2479 review: _reload() mutated _resolution without setState,
      // so after a successful save the source caption and the Clear
      // button stayed stale until an ancestor rebuilt.
      var resolution = const AppContextCapResolution(
        65536,
        AppContextCapSource.user,
      );
      await _pump(
        tester,
        ContextWindowCapSection(
          resolve: ({projectDir, homeDir}) => resolution,
          write: (value, {required layer, projectDir, homeDir}) async {
            // The write clears the cap at the layer it edited.
            resolution = const AppContextCapResolution(
              null,
              AppContextCapSource.none,
            );
            return '/home/.fah/config.yaml';
          },
        ),
      );
      expect(find.textContaining('user ~/.fah/config.yaml'), findsOneWidget);
      expect(find.text('Clear cap'), findsOneWidget);
      await tester.tap(find.text('Clear cap'));
      await tester.pump();
      expect(
        find.textContaining('user ~/.fah/config.yaml'),
        findsNothing,
        reason: 'the caption follows the post-save re-resolution',
      );
      expect(
        find.text('Clear cap'),
        findsNothing,
        reason: 'the Clear button disappears with the cap',
      );
    });

    testWidgets('web: the not-configurable note replaces the field', (
      tester,
    ) async {
      await _pump(tester, const ContextWindowCapSection(supported: false));
      expect(find.byKey(const ValueKey('contextWindowCapField')), findsNothing);
      expect(find.textContaining('Not configurable'), findsOneWidget);
    });
  });
}
