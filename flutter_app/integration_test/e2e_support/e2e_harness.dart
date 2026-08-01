// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Shared harness for REAL-agent end-to-end tests (real LLM endpoint,
/// real sandbox env, real JS engines on the macOS host).
///
/// Every helper stays small on purpose (the CRAP gate applies the same
/// discipline to test code as to lib code). Scenarios read linearly:
///
/// ```dart
/// final world = await bootRealAgent(tester);
/// await runAgent(tester, world.service, 'Create a tiny notes app');
/// await expectApp(world.apps, 'notes-mini');
/// await pumpLauncherSettled(tester, world.manager);
/// expectTileBooted(tester);
/// ```
library;

import 'dart:async';
import 'dart:convert';

import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

export 'package:fa/apps/app_tile_host.dart' show AppTileHost;

/// The real-LLM key, injected with `--dart-define=KIMI_TEST_KEY=...`
/// (never committed; without it every E2E test self-skips).
const e2eKey = String.fromEnvironment('KIMI_TEST_KEY');

/// True when a real-LLM key is available for E2E runs.
bool get e2eEnabled => e2eKey.isNotEmpty;

/// Everything one real-agent E2E scenario needs, created by
/// [bootRealAgent].
final class E2eWorld {
  const E2eWorld({
    required this.env,
    required this.manager,
    required this.apps,
    required this.service,
  });

  /// The real platform sandbox env.
  final ExecutionEnv env;

  /// The session manager over [env] (`<cwd>/sessions`).
  final FlutterSessionManager manager;

  /// The apps store over the same env.
  final AppsStore apps;

  /// The first (main) agent service.
  final AgentService service;
}

/// The Kimi-for-Coding endpoint config for real-agent runs.
AgentConfig e2eConfig() => AgentConfig(
  providerKind: 'openai-completions',
  modelId: 'kimi-for-coding',
  baseUrl: 'https://api.kimi.com/coding/v1',
  apiKey: e2eKey,
);

/// Boots the production stack exactly the way the app does: the real
/// platform env, `AgentService.create` (full tools, prompts, secrets).
Future<E2eWorld> bootRealAgent(WidgetTester tester) async {
  final env = await createPlatformEnv();
  final manager = FlutterSessionManager(
    env: env,
    sessionsRoot: '${env.cwd}/sessions',
  );
  final service = await tester.runAsync(
    () => AgentService.create(config: e2eConfig(), env: env),
  );
  if (service == null) fail('AgentService.create returned null');
  addTearDown(service.dispose);
  await tester.runAsync(service.initialize);
  manager.addSession('e2e-main', service);
  return E2eWorld(
    env: env,
    manager: manager,
    apps: AppsStore(env),
    service: service,
  );
}

/// Sends [prompt] and waits for the run — on the REAL event loop
/// (network + JS engines do not advance inside the fake zone), with a
/// hard cap and an error assertion.
Future<void> runAgent(
  WidgetTester tester,
  AgentService service,
  String prompt, {
  Duration timeout = const Duration(minutes: 6),
}) async {
  await tester.runAsync(() async {
    await service.sendText(prompt);
    await service.waitForIdle().timeout(
      timeout,
      onTimeout: () =>
          fail('agent run did not finish in $timeout; error: ${service.error}'),
    );
  });
  expect(service.error, isNull, reason: 'the run must not fail');
}

/// Opens ANOTHER session on the same manager (parallel-app scenarios).
Future<AgentService> openSecondSession(E2eWorld world, String id) async {
  final managed = await world.manager.createSession(
    config: e2eConfig(),
    serviceFactory: () =>
        AgentService.create(config: e2eConfig(), env: world.env),
  );
  addTearDown(managed.service.dispose);
  return managed.service;
}

/// Pumps the launcher over [manager] and lets it settle (bounded: tile
/// engines never "settle" on their own).
Future<void> pumpLauncherSettled(
  WidgetTester tester,
  FlutterSessionManager manager,
) async {
  await tester.pumpWidget(
    MaterialApp(home: AppLauncherScreen(manager: manager)),
  );
  await pumpBounded(tester);
}

/// Pumps [frames] bounded frames at 400 ms (layout reloads, engine
/// boots, debounced fsRevision reloads all land within it).
Future<void> pumpBounded(WidgetTester tester, {int frames = 15}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// Reads and parses a JSON file from the env (fails when missing or
/// invalid).
Future<Map<String, Object?>> readEnvJson(ExecutionEnv env, String path) async {
  final text = (await env.readTextFile(path)).valueOrNull;
  expect(text, isNotNull, reason: '$path must exist');
  return jsonDecode(text!) as Map<String, Object?>;
}

/// The app with [id] from the store (fails when absent).
Future<JsAppInfo> expectApp(AppsStore store, String id) async {
  final apps = await store.listApps();
  return apps.firstWhere(
    (a) => a.id == id,
    orElse: () => fail(
      'app "$id" missing from the store; have: ${apps.map((a) => a.id)}',
    ),
  );
}

/// Asserts every live tile on the grid finished booting into a real
/// tree: no boot spinner and no error fallback icon anywhere.
void expectTileBooted(WidgetTester tester) {
  final tiles = find.byType(AppTileHost);
  expect(tiles, findsWidgets);
  expect(
    find.descendant(
      of: tiles,
      matching: find.byType(CircularProgressIndicator),
    ),
    findsNothing,
    reason: 'live tiles must finish booting',
  );
  expect(
    find.descendant(of: tiles, matching: find.byType(AppIcon)),
    findsNothing,
    reason: 'live tiles must render their trees, not the error fallback',
  );
}

/// Unmounts the launcher so tile engines and their timers dispose
/// cleanly before the test ends.
Future<void> unmountAll(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}
