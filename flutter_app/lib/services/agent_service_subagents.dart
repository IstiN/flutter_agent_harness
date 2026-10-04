// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

part of 'agent_service.dart';

/// Subagent observe/send surface of [AgentService] (the settings
/// Agents section) plus the dynamic-messages host factory and the
/// widget secret-request backend (issue #102). The private managers
/// stay on the class; static helpers are qualified with
/// [AgentService] (extensions resolve unqualified statics of the
/// extended type only via the class name).
extension AgentServiceSubagents on AgentService {
  /// The session's retained-subagent registry (null before the agent is
  /// built). The settings Agents section renders the live tree from it.
  SubagentManager? get subagentManager => _subagentManager;

  /// Test-only injection: the lightweight constructor (pre-built agent)
  /// never builds the messaging fabric, so widget tests that exercise
  /// subagent surfaces (badge, task list) install a bare manager here.
  @visibleForTesting
  set subagentManager(SubagentManager? manager) => _subagentManager = manager;

  /// Reads the last [tail] messages of subagent [id]'s session as
  /// `(role, text)` pairs (settings Agents section → observe). Empty when
  /// the child session is unavailable or the id is unknown.
  Future<List<(String, String)>> observeSubagent(
    String id, {
    int tail = 20,
  }) async {
    final handle = _subagentManager?[id];
    if (handle == null) return const [];
    try {
      final exists = await env.fileInfo(handle.sessionId);
      if (exists.valueOrNull == null) return const [];
      final session = await _repo.open(_subagentSessionMetadata(handle));
      return AgentService.tailMessagePairs(
        await session.buildContextMessages(),
        tail,
      );
    } on Object {
      return const [];
    }
  }

  /// Sends a follow-up message to subagent [id] (settings Agents section →
  /// send): appends to the child session and marks it resumed. Falls back to
  /// the sibling pending-queue when the session is unavailable.
  Future<void> sendToSubagent(String id, String message) async {
    final handle = _subagentManager?[id];
    if (handle == null) {
      throw StateError('no subagent "$id"');
    }
    AgentService.ensureSendableSubagent(handle, id);
    try {
      final session = await _repo.open(_subagentSessionMetadata(handle));
      await session.appendMessage(UserMessage.text(message));
    } on Object {
      // Fall back to the sibling pending queue when the session is gone.
      await _subagentManager!.enqueueMessage(
        id,
        SubagentMessage(
          fromId: 'parent',
          text: message,
          sentAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      return;
    }
    await _subagentManager!.update(id, status: SubagentStatus.running);
  }

  /// The child-transcript metadata both observe and send open the session
  /// with (epoch creation time; the path IS the session id).
  SessionMetadata _subagentSessionMetadata(SubagentHandle handle) {
    return SessionMetadata(
      id: handle.sessionId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      cwd: env.sessionCwd,
      path: handle.sessionId,
    );
  }

  DynamicMessagesService _buildDynamicMessages() => DynamicMessagesService(
    env: env,
    sendText: sendText,
    sessionIdOf: () => _sessionId,
    sessionFileOf: () => _sessionFile,
    mediaGatewayOf: () => _mediaGateway,
    videoReaderOf: () => _videoReader,
    hostSecretsOf: hostSecrets,
    llmHandlerOf: () => completeOnce,
    asrTranscriberOf: resolveAsrTranscriber,
    resolveHostSecretDefault: _requestSecretForWidget,
  );

  /// The `jsr.fa.keys.request` backend for widget engines without a tile-
  /// supplied requester: the same secret sheet the `request_secret` tool
  /// drives, with grants routed through the session's persist+activate
  /// flow (JsAppView parity).
  Future<RequestSecretResult?> _requestSecretForWidget(
    String name,
    String reason,
  ) async {
    final result = await secretRequestHandler?.call(name, reason);
    if (result == null) return null;
    return acceptSecretGrant(result);
  }
}
