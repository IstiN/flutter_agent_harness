// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

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
AgentTool openAppTool(ExecutionEnv env, {required AppLauncher launcher}) {
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
      await launcher(app);
      return ToolExecutionResult.text("Opened app '${app.name}'");
    },
  );
}
