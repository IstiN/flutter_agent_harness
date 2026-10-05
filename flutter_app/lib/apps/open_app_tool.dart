// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/apps/app_preflight.dart';
import 'package:fa/apps/apps_store.dart';

/// Name of the agent tool that opens a JS app in the Fa UI.
const openAppToolName = 'open_app';

/// Host callback that opens [app] for the user — the chat screen installs it
/// and pushes the app's [JsAppView]. `null` on the service unregisters the
/// tool (the safe headless default).
typedef AppLauncher = FutureOr<void> Function(JsAppInfo app);

/// Creates the `open_app` tool bound to [launcher].
///
/// A host-UI capability registered by the Flutter app only (never in core
/// `builtinTools`): the model names an app id from the env's `apps/` folder
/// and the host navigates to it. Unknown ids fail with the list of available
/// ids so the model can recover. The description/result texts are LLM-facing
/// and stay literal English (not UI copy).
///
/// gh-1164 Part C: the pre-flight gate ([runAppPreflight]) runs BEFORE the
/// launcher — the tool NEVER returns success for an app whose standing
/// test is red or whose JS fails to load/render (the no-fake-success
/// contract, AC7). The default gate uses the real wiring; tests inject
/// their own. `null` disables the gate (hosts with no JS engine at all —
/// installing a gate there would fail every healthy app).
AgentTool openAppTool(
  ExecutionEnv env, {
  required AppLauncher launcher,
  Future<AppPreflightOutcome?> Function(String appId)? preflight,
}) {
  return AgentTool(
    name: openAppToolName,
    label: 'open_app',
    // Opening an app only navigates the UI — nothing is mutated.
    tier: ApprovalTier.read,
    description:
        "Open one of the user's JS apps in the Fa UI: the host navigates to "
        'the app so the user sees it. Use when the user asks to see or open '
        'an app, or to show an app you just created or edited. Apps live in '
        'the apps/ folder (apps/<id>/manifest.json) — list it with your file '
        'tools to discover ids, or use an id from a provided list.',
    parameters: const {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': 'Id of the app to open (its apps/<id> folder name)',
        },
      },
      'required': ['id'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final id = arguments['id']?.toString().trim() ?? '';
      if (id.isEmpty) {
        throw StateError('open_app needs a non-empty "id"');
      }
      final apps = await AppsStore(env).listApps();
      JsAppInfo? match;
      for (final app in apps) {
        if (app.id == id) match = app;
      }
      final app = match;
      if (app == null) {
        final available = apps.map((a) => a.id).join(', ');
        throw StateError(
          'unknown app "$id" — available apps: '
          '${available.isEmpty ? '(none installed)' : available}',
        );
      }
      // Issue #866: a manifest the agent broke is surfaced, not launched.
      final error = app.error;
      if (error != null) {
        throw StateError('app "$id" is broken: $error');
      }
      // gh-1164 Part C (AC7): the pre-flight gate runs BEFORE the handover
      // — a red standing test or a broken smoke render fails the tool
      // call with the excerpt; only a passed (or absent) gate launches.
      final gate = preflight;
      if (gate != null) {
        final outcome = await gate(id);
        if (outcome is AppPreflightFailed) {
          throw StateError(outcome.toString());
        }
      }
      await launcher(app);
      return ToolExecutionResult.text("Opened app '${app.name}'");
    },
  );
}
