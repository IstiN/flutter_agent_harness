// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';

/// App-open navigation shared by the session sidebar's Apps section and the
/// agent's `open_app` tool (see `open_app_tool.dart`): both push the same
/// [JsAppView] with the same wiring.

/// Resolves the session bound to [appId] (`apps/<id>/session.json`),
/// switching [manager] to it. Returns null when no (valid) binding exists —
/// the caller then uses the active session or creates one.
Future<AgentService?> resolveAppBoundSession(
  FlutterSessionManager manager,
  String appId,
) async {
  final active = manager.active?.service;
  if (active == null) return null;
  final raw = await active.env.readTextFile('apps/$appId/session.json');
  final text = raw.valueOrNull;
  if (text == null) return null;
  String? boundId;
  try {
    boundId = (jsonDecode(text) as Map<String, dynamic>)['sessionId']
        ?.toString();
  } on FormatException {
    return null;
  }
  if (boundId == null || boundId.isEmpty) return null;
  // Already open in this app run?
  for (final session in manager.sessions) {
    if (session.id == boundId) {
      manager.switchTo(boundId);
      return session.service;
    }
  }
  // Open it from disk.
  final all = await active.listSessions();
  for (final metadata in all) {
    if (metadata.id == boundId) {
      final managed = await manager.openSession(
        metadata,
        config:
            active.configForClone ??
            AgentConfig(
              providerKind: active.providerKind,
              modelId: active.modelId,
              baseUrl: '',
              apiKey: '',
            ),
        serviceFactory: () => active.clone(),
      );
      return managed.service;
    }
  }
  return null; // stale binding (session deleted)
}

/// Creates a fresh session dedicated to [appId] and records the binding.
Future<AgentService> createAppBoundSession(
  FlutterSessionManager manager,
  String appId,
) async {
  final active = manager.active!.service;
  final config =
      active.configForClone ??
      AgentConfig(
        providerKind: active.providerKind,
        modelId: active.modelId,
        baseUrl: '',
        apiKey: '',
      );
  final managed = await manager.createSession(
    config: config,
    serviceFactory: () async => active.clone(),
  );
  await active.env.writeFile(
    'apps/$appId/session.json',
    '{"sessionId":"${managed.id}"}',
  );
  return managed.service;
}

/// Forwards an in-app Fa message (text + app state + screenshot) to the
/// session bound to the app (creating + binding one on first contact).
Future<void> forwardAppMessageToAgent(
  FlutterSessionManager manager,
  FaAppMessage message,
) async {
  final appId = message.appId;
  final service = appId == null
      ? manager.active?.service
      : (await resolveAppBoundSession(manager, appId) ??
            await createAppBoundSession(manager, appId));
  if (service == null) return;
  final buffer = StringBuffer(message.text);
  final stateJson = message.appStateJson;
  if (stateJson != null) {
    buffer.write('\n\nCurrent app state:\n```json\n$stateJson\n```');
  }
  final screenshot = message.screenshot;
  if (screenshot != null) {
    await service.sendImage(
      bytes: screenshot,
      mimeType: 'image/png',
      text: buffer.toString(),
    );
  } else {
    await service.sendText(buffer.toString());
  }
}

/// Pushes the [JsAppView] for [app] — the exact navigation the sidebar's
/// Apps section performs, so the agent's `open_app` tool and a user tap land
/// on the same screen with the same wiring. An app with a bound session
/// resumes it on open. [permissionsStore] is loaded from the env when not
/// given.
Future<void> pushJsApp(
  BuildContext context, {
  required FlutterSessionManager manager,
  required JsAppInfo app,
  AppPermissionsStore? permissionsStore,
}) async {
  final service = manager.active?.service;
  if (service == null) return;
  final store = permissionsStore ?? await AppPermissionsStore.load(service.env);
  final appService = await resolveAppBoundSession(manager, app.id) ?? service;
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => JsAppView(
        app: app,
        env: service.env,
        permissionsStore: store,
        llmHandler: service.completeOnce,
        onSendToAgent: (message) => forwardAppMessageToAgent(manager, message),
        fsRevision: service.fsRevision,
        agentService: appService,
      ),
    ),
  );
}
