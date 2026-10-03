// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:fa/apps/app_state_context.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa_ui/fa_ui.dart' show FaChatHost;
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show FileErrorCode;

/// App-open navigation shared by the session sidebar's Apps section and the
/// agent's `open_app` tool (see `open_app_tool.dart`): both push the same
/// [JsAppView] with the same wiring.

/// Resolves the session bound to [appId] (`apps/<id>/session.json`),
/// switching [manager] to it. Returns null when no (valid) binding exists —
/// the caller then uses the active session or creates one.
Future<AgentService?> resolveAppBoundSession(
  FlutterSessionManager manager,
  String appId,
) async => (await _resolveAppBinding(manager, appId)).$1;

/// How [_resolveAppBinding] ended (issue #864): the distinction decides
/// whether the caller may MINT. `firstContact` covers "no binding yet" AND
/// bindings that can be healed by rewriting them (corrupt file, stale id);
/// `unopenable` covers a real binding whose session cannot be opened right
/// now (torn session file, live lease elsewhere, too large) — minting a
/// replacement there is the proliferation the owner flagged: every open
/// would mint a fresh session and overwrite the binding. Fall back to the
/// active session instead and keep the binding for a later repair.
enum _AppBindingResolution { bound, firstContact, unopenable }

Future<(AgentService?, _AppBindingResolution)> _resolveAppBinding(
  FlutterSessionManager manager,
  String appId,
) async {
  final active = manager.active?.service;
  if (active == null) return (null, _AppBindingResolution.unopenable);
  String? boundId;
  try {
    final raw = await active.env.readTextFile('apps/$appId/session.json');
    if (raw.isErr) {
      final code = raw.errorOrNull!.code;
      if (code != FileErrorCode.notFound) {
        // A real read failure (permission, is-a-directory, IO) is NOT
        // absence: minting here would rewrite a binding we could not
        // even read — the per-message proliferation the owner flagged.
        // Keep the binding; run on the active session (issue #864).
        AppLog.i(
          'apps',
          'binding read failed for $appId (${code.name}) — keeping binding',
        );
        return (null, _AppBindingResolution.unopenable);
      }
      return (null, _AppBindingResolution.firstContact); // no binding yet
    }
    // A torn or agent-written file (seen on-device: a fitness-trainer
    // tap silently dead) may hold any JSON shape; only a map with an id
    // binds. Everything else heals by rewriting the binding on the mint.
    final decoded = jsonDecode(raw.valueOrNull!);
    boundId = decoded is Map<String, dynamic>
        ? decoded['sessionId']?.toString()
        : null;
  } on Object catch (error) {
    AppLog.i('apps', 'resolve bound session failed for $appId: $error');
    return (null, _AppBindingResolution.firstContact);
  }
  if (boundId == null || boundId.isEmpty) {
    return (null, _AppBindingResolution.firstContact);
  }
  // Already open in this app run?
  for (final session in manager.sessions) {
    if (session.id == boundId) {
      manager.switchTo(boundId);
      return (session.service, _AppBindingResolution.bound);
    }
  }
  // Open it from disk. A failure here is NOT first contact — the binding
  // is real — so it must never route into a re-mint (issue #864).
  try {
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
        return (managed.service, _AppBindingResolution.bound);
      }
    }
  } on Object catch (error) {
    AppLog.i('apps', 'bound session unopenable for $appId: $error');
    return (null, _AppBindingResolution.unopenable);
  }
  // Stale binding (session deleted): rewriting it on the mint heals.
  return (null, _AppBindingResolution.firstContact);
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
  // Issue #864: the binding write must be checked — a silently failed
  // write would leave the app on "first contact" forever, re-minting on
  // every message. Surface the failure instead of faking progress.
  final written = await active.env.writeFile(
    'apps/$appId/session.json',
    '{"sessionId":"${managed.id}"}',
  );
  if (written.isErr) {
    throw StateError(
      'app binding write failed for $appId: ${written.errorOrNull!}',
    );
  }
  return managed.service;
}

/// One mint in flight per app (issue #864 E3): overlapping forwards to the
/// same app share a single first-contact session instead of double-minting.
final _appBindInFlight = <String, Future<AgentService>>{};

Future<AgentService> _createAppBoundSessionOnce(
  FlutterSessionManager manager,
  String appId,
) {
  final inFlight = _appBindInFlight[appId];
  if (inFlight != null) return inFlight;
  // BLOCK body: an expression closure would return the removed value —
  // the future itself — making the result future wait on itself.
  final future = createAppBoundSession(manager, appId).whenComplete(() {
    _appBindInFlight.remove(appId);
  });
  _appBindInFlight[appId] = future;
  return future;
}

/// Forwards an in-app Fa message (text + app state + theme + screenshot) to
/// the session bound to the app (creating + binding one on first contact).
/// Returns the session service that received the message — on first contact
/// that is the NEWLY created app-bound session, not the one the caller may
/// already hold — or null when there is no session to talk to.
Future<AgentService?> forwardAppMessageToAgent(
  FlutterSessionManager manager,
  FaAppMessage message,
) async {
  final appId = message.appId;
  AgentService? service;
  if (appId == null) {
    service = manager.active?.service;
  } else {
    final (resolved, outcome) = await _resolveAppBinding(manager, appId);
    if (resolved != null) {
      service = resolved;
    } else if (outcome == _AppBindingResolution.firstContact) {
      // Mint exactly once per app (issue #864): first contact only —
      // never per open, never per message. A mint failure (binding
      // write denied, clone rejected) must not drop the user's message
      // as an unhandled zone error: log it and run on the active
      // session; the binding heals on a later mint.
      try {
        service = await _createAppBoundSessionOnce(manager, appId);
      } on Object catch (error) {
        AppLog.i('apps', 'app binding mint failed for $appId: $error');
        service = manager.active?.service;
      }
    } else {
      // A real binding that cannot be opened right now: continue on the
      // active session, keep the binding untouched — never mint a
      // replacement (issue #864).
      service = manager.active?.service;
    }
  }
  if (service == null) return null;
  final buffer = StringBuffer(message.text);
  final stateJson = message.appStateJson;
  if (stateJson != null) {
    // Issue #692 D: the state block is budgeted (8 KiB default) — an
    // oversized export folds to keys + previews instead of an 82 KB user
    // message; the fold is announced in the block itself.
    final bounded = formatAppStateContext(stateJson);
    final fence = identical(bounded, stateJson) ? 'json' : '';
    buffer.write('\n\nCurrent app state:\n```$fence\n$bounded\n```');
  }
  final viewportLine = message.viewportLine;
  if (viewportLine != null) {
    buffer.write('\n$viewportLine');
  }
  final themeLine = message.themeLine;
  if (themeLine != null) {
    buffer.write('\n$themeLine');
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
  return service;
}

/// Pushes the [JsAppView] for [app] — the exact navigation the sidebar's
/// Apps section performs, so the agent's `open_app` tool and a user tap land
/// on the same screen with the same wiring. An app with a bound session
/// resumes it on open. [permissionsStore] is loaded from the env when not
/// given. [source] labels the analytics event ('launcher' / 'tool').
Future<void> pushJsApp(
  BuildContext context, {
  required FlutterSessionManager manager,
  required JsAppInfo app,
  required String source,
  AppPermissionsStore? permissionsStore,
}) async {
  final service = manager.active?.service;
  if (service == null) return;
  AppAnalytics.instance.jsAppOpened(
    isDemo: AppsStore.demoAppIds.contains(app.id),
    source: source,
  );
  final store = permissionsStore ?? await AppPermissionsStore.load(service.env);
  final appService = await resolveAppBoundSession(manager, app.id) ?? service;
  if (!context.mounted) return;
  // Wide screens: the apps side panel owns a nested Navigator registered on
  // FaChatHost. Push there instead of over the whole shell — the agent's
  // open_app then refreshes the panel's app in place (and shows the right
  // panel layout with its own padding), never a full-screen takeover.
  final panelNavigator = FaChatHost.jsAppNavigatorKey?.currentState;
  final navigator = panelNavigator ?? Navigator.of(context);
  await navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => JsAppView(
        app: app,
        env: service.env,
        permissionsStore: store,
        llmHandler: service.completeOnce,
        onSendToAgent: (message) => forwardAppMessageToAgent(manager, message),
        fsRevision: service.fsRevision,
        agentService: appService,
        embeddedInPanel: panelNavigator != null,
      ),
    ),
  );
}
