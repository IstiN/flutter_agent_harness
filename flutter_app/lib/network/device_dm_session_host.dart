// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show SessionMetadata;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';

/// Service-layer boundary used by the device connector to inject a remote
/// viewer's plain user text and obtain the resulting assistant text.
abstract interface class DeviceDmSessionHost {
  /// Delivers one user turn, optionally to an explicit persisted session id.
  /// Returns only assistant text produced by this turn (null when none).
  Future<String?> deliverUserText({String? sessionId, required String text});
}

/// Routes DMs through the app's real session owner. An offline target is
/// opened from disk through [FlutterSessionManager.openSession] before its
/// [AgentService] receives the turn; no process or second session writer is
/// spawned.
final class FlutterDeviceDmSessionHost implements DeviceDmSessionHost {
  /// Creates a host over the app's multi-session manager.
  const FlutterDeviceDmSessionHost(this.sessions);

  /// The app's session owner and disk-open authority.
  final FlutterSessionManager sessions;

  @override
  Future<String?> deliverUserText({
    String? sessionId,
    required String text,
  }) async {
    final managed = await _resolve(sessionId);
    final service = managed.service;
    final firstNewRow = service.messages.length;
    await service.sendText(text);
    await _settleTurn(service);
    return _newAssistantText(service, firstNewRow);
  }

  Future<FlutterManagedSession> _resolve(String? sessionId) async {
    final loaded = _loadedTarget(sessionId);
    if (loaded != null) return loaded;
    final persisted = await sessions.listPersistedSessions();
    final metadata = _persistedTarget(persisted, sessionId);
    if (metadata == null) {
      throw StateError('DM target session not found: ${sessionId ?? '<last>'}');
    }
    return _openPersisted(metadata);
  }

  FlutterManagedSession? _loadedTarget(String? sessionId) {
    if (sessionId != null && sessionId.isNotEmpty) {
      return sessions.sessions
          .where((session) => session.id == sessionId)
          .firstOrNull;
    }
    // Both live and persisted projections are newest-first.
    return sessions.active ?? sessions.sessions.firstOrNull;
  }

  SessionMetadata? _persistedTarget(
    List<SessionMetadata> persisted,
    String? sessionId,
  ) {
    if (sessionId == null || sessionId.isEmpty) return persisted.firstOrNull;
    return persisted.where((row) => row.id == sessionId).firstOrNull;
  }

  Future<FlutterManagedSession> _openPersisted(SessionMetadata metadata) async {
    final template =
        sessions.active?.service ??
        sessions.sessions.firstOrNull?.service ??
        AgentService.maybeCurrent;
    if (template == null) {
      throw StateError('no local AgentService available to open a DM session');
    }
    final config =
        template.configForClone ??
        AgentConfig(
          providerKind: template.providerKind,
          modelId: template.modelId,
          baseUrl: '',
          apiKey: '',
        );
    return sessions.openSession(
      metadata,
      config: config,
      serviceFactory: () => template.clone(),
    );
  }

  Future<void> _settleTurn(AgentService service) async {
    do {
      await service.waitForIdle();
      // AgentService schedules queued steering/follow-up runs one event-loop
      // turn after agent_end. Let that run start before declaring this DM done.
      await Future<void>.delayed(Duration.zero);
    } while (service.isStreaming || service.pendingSteerTexts.isNotEmpty);
  }

  String? _newAssistantText(AgentService service, int firstNewRow) {
    for (var i = service.messages.length - 1; i >= firstNewRow; i--) {
      final row = service.messages[i];
      if (row.role == 'assistant' && row.content.trim().isNotEmpty) {
        return row.content;
      }
    }
    return null;
  }
}
