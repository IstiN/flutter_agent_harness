/// Pure-Dart A2A server request handler (Phase 5b).
///
/// Transport-agnostic: receives JSON-RPC request bodies and returns
/// JSON-RPC response bodies. The HTTP mounting lives in `bin/` + `lib/io.dart`
/// (same split as MCP's transport layer). This file is pure Dart — no
/// `dart:io`.
library;

import 'dart:async';
import 'dart:convert';

import 'a2a_client.dart';

/// Injected agent runner: processes a user message and returns the response.
typedef A2aAgentRunner = Future<String> Function(String userMessage);

/// A transport-agnostic A2A request handler. Each incoming JSON-RPC request
/// is dispatched to [runner]; the task state is tracked in-memory keyed by
/// task id.
final class A2aRequestHandler {
  A2aRequestHandler({
    required this.runner,
    required this.agentName,
    required this.agentDescription,
    this.skills = const [],
    this.token,
  });

  final A2aAgentRunner runner;
  final String agentName;
  final String agentDescription;
  final List<AgentSkill> skills;
  final String? token;

  final _tasks = <String, A2aTask>{};
  var _idCounter = 0;

  /// Handles a raw JSON-RPC request body, returns the JSON-RPC response body.
  Future<String> handle(String requestBody, {String? authHeader}) async {
    if (token != null && authHeader != 'Bearer $token') {
      return _error(null, -32001, 'unauthorized');
    }
    try {
      final decoded = jsonDecode(requestBody);
      if (decoded is! Map) return _error(null, -32600, 'invalid request');
      final req = decoded.cast<String, dynamic>();
      final id = req['id'];
      final method = req['method'] as String?;
      final params = (req['params'] as Map?)?.cast<String, dynamic>() ?? {};
      final result = switch (method) {
        'message/send' => _handleSend(params),
        'tasks/get' => _handleGet(params),
        'tasks/cancel' => _handleCancel(params),
        _ => throw A2aException('unknown method: $method'),
      };
      return _ok(id, await result);
    } on A2aException catch (e) {
      return _error(null, -32603, e.message);
    } on Object catch (e) {
      return _error(null, -32603, '$e');
    }
  }

  /// Serves the Agent Card at `/.well-known/agent.json`.
  String agentCardJson() => jsonEncode({
    'name': agentName,
    'description': agentDescription,
    'url': '',
    'version': '1.0.0',
    'capabilities': {
      'inputModes': ['text'],
      'outputModes': ['text'],
      'streaming': false,
    },
    'skills': [
      for (final s in skills)
        {'id': s.id, 'name': s.name, 'description': s.description},
    ],
    if (token != null)
      'authentication': {
        'schemes': ['bearer'],
      },
  });

  Future<Map<String, dynamic>> _handleSend(Map<String, dynamic> params) async {
    final msg = params['message'];
    if (msg is! Map) throw A2aException('missing message');
    final partsRaw = msg['parts'] as List? ?? const [];
    final parts = partsRaw
        .map(
          (p) => p is Map
              ? A2aPart.fromJson(p.cast<String, dynamic>())
              : const A2aPart(text: ''),
        )
        .toList();
    final text = parts
        .where((p) => p.text != null)
        .map((p) => p.text!)
        .join('\n');
    if (text.isEmpty) throw A2aException('empty message');

    final taskId = 'task-${++_idCounter}';
    final task = A2aTask(
      id: taskId,
      state: A2aTaskState.working,
      messages: [
        A2aMessage(
          role: 'user',
          parts: [A2aPart(text: text)],
        ),
      ],
    );
    _tasks[taskId] = task;

    // Run the agent (synchronous within this request).
    try {
      final response = await runner(text);
      task.state = A2aTaskState.completed;
      task.messages.add(
        A2aMessage(
          role: 'agent',
          parts: [A2aPart(text: response)],
        ),
      );
      task.artifacts.add(A2aArtifact(parts: [A2aPart(text: response)]));
    } on Object catch (e, st) {
      task.state = A2aTaskState.failed;
      task.messages.add(
        A2aMessage(
          role: 'agent',
          parts: [A2aPart(text: 'error: $e')],
        ),
      );
    }

    return _taskJson(task);
  }

  Future<Map<String, dynamic>> _handleGet(Map<String, dynamic> params) async {
    final taskId = params['taskId'] as String?;
    final task = taskId != null ? _tasks[taskId] : null;
    if (task == null) throw A2aException('task not found: $taskId');
    return _taskJson(task);
  }

  Future<Map<String, dynamic>> _handleCancel(
    Map<String, dynamic> params,
  ) async {
    final taskId = params['taskId'] as String?;
    final task = taskId != null ? _tasks[taskId] : null;
    if (task == null) throw A2aException('task not found: $taskId');
    task.state = A2aTaskState.canceled;
    return _taskJson(task);
  }

  Map<String, dynamic> _taskJson(A2aTask task) => {
    'id': task.id,
    'status': {'state': task.state.toSpecString()},
    'messages': [for (final m in task.messages) m.toJson()],
    if (task.artifacts.isNotEmpty)
      'artifacts': [
        for (final a in task.artifacts)
          {
            'parts': [for (final p in a.parts) p.toJson()],
          },
      ],
  };

  String _ok(dynamic id, Map<String, dynamic> result) =>
      jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result});

  String _error(dynamic id, int code, String message) => jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  });
}
