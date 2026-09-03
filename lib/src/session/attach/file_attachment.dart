/// File-backed attached-session transport: [SessionEventSource] tails
/// the session JSONL through the [ExecutionEnv] filesystem; the input
/// channel rides the agent messaging fabric ([AgentMessageKind.user] to
/// the session's `main` mailbox). Works for any two Fa processes sharing
/// the sessions root (the macOS App Group) — the CLI owns the JSONL, the
/// app only reads it and hands input over.
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import '../../context.dart';
import 'package:flutter_sandbox/flutter_sandbox.dart';
import '../../messaging/agent_message.dart';
import '../../messaging/file_messaging_repository.dart';
import '../../types.dart';
import '../session_record.dart';
import 'session_attachment.dart';

final class FileSessionEventSource implements SessionEventSource {
  /// Creates the source. [resolvePath] maps a session id to its JSONL
  /// path (the host resolves it however it likes — typically
  /// `JsonlSessionRepo.list` metadata); [pollInterval] is injectable for
  /// tests.
  FileSessionEventSource({
    required ExecutionEnv env,
    required Future<String?> Function(String sessionId) resolvePath,
    Duration pollInterval = const Duration(seconds: 1),
  }) : _env = env,
       _resolvePath = resolvePath,
       _pollInterval = pollInterval;

  final ExecutionEnv _env;
  final Future<String?> Function(String sessionId) _resolvePath;
  final Duration _pollInterval;

  final _controllers = <String, StreamController<AttachedSessionEvent>>{};
  final _watchers = <String, Future<void>>{};
  final _deliveredLines = <String, int>{};
  final _disposed = false;

  @override
  Stream<AttachedSessionEvent> watch(String sessionId) {
    final existing = _controllers[sessionId];
    if (existing != null) return existing.stream;
    final controller = StreamController<AttachedSessionEvent>();
    _controllers[sessionId] = controller;
    _watchers[sessionId] = _runWatcher(sessionId, controller);
    return controller.stream;
  }

  Future<void> _runWatcher(
    String sessionId,
    StreamController<AttachedSessionEvent> controller,
  ) async {
    // First poll establishes the baseline and emits the backlog; every
    // later poll emits only what grew. A missing file is not an error —
    // the owning process creates the JSONL lazily.
    while (!controller.isClosed && !_disposed) {
      final path = await _resolvePath(sessionId);
      final lines = path == null
          ? null
          : (await _env.readTextLines(path)).valueOrNull;
      final total = lines?.length ?? 0;
      final start = _deliveredLines[sessionId];
      if (start == null) {
        _deliveredLines[sessionId] = total;
        if (lines != null) await _emit(sessionId, controller, lines, 0);
      } else if (total > start) {
        _deliveredLines[sessionId] = total;
        await _emit(sessionId, controller, lines ?? const [], start);
      }
      await Future<void>.delayed(_pollInterval);
    }
  }

  Future<void> _emit(
    String sessionId,
    StreamController<AttachedSessionEvent> controller,
    List<String> lines,
    int start,
  ) async {
    final appended = <AttachedMessage>[];
    for (final line in lines.skip(start)) {
      final row = _rowFromLine(line);
      if (row != null) appended.add(row);
    }
    if (appended.isEmpty || controller.isClosed) return;
    controller.add(AttachedSessionEvent(appended: appended));
  }

  /// One JSONL line → render row; null for records the view skips
  /// (headers, compaction markers, tool results …).
  AttachedMessage? _rowFromLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) return null;
      json = decoded;
    } on Object {
      return null; // torn write — the next poll re-reads cleanly
    }
    if (json['type'] != 'message') return null;
    final MessageRecord record;
    try {
      final parsed = SessionRecord.fromJson(json);
      if (parsed is! MessageRecord) return null;
      record = parsed;
    } on Object {
      return null;
    }
    return attachedRowFromMessage(record.message);
  }

  @override
  Future<void> dispose() async {
    for (final controller in _controllers.values) {
      if (!controller.isClosed) await controller.close();
    }
    _controllers.clear();
    _watchers.clear();
    _deliveredLines.clear();
  }
}

/// Renders one conversation [Message] as an attached-view row, or null
/// for content the view skips (tool results, empty rows).
AttachedMessage? attachedRowFromMessage(Message message) {
  switch (message) {
    case UserMessage():
      final text = _textOf(message.content);
      if (text == null) return null; // tool results arrive as user rows
      return AttachedMessage(role: AttachedMessageRole.user, text: text);
    case AssistantMessage():
      final text = _textOf(message.content);
      if (text != null && text.isNotEmpty) {
        return AttachedMessage(role: AttachedMessageRole.assistant, text: text);
      }
      final toolName = _toolNameOf(message.content);
      if (toolName != null) {
        return AttachedMessage(
          role: AttachedMessageRole.tool,
          text: '',
          toolName: toolName,
        );
      }
      return null;
    default:
      return null;
  }
}

String? _textOf(Object content) {
  switch (content) {
    case String():
      return content.isEmpty ? null : content;
    case List():
      final buf = StringBuffer();
      for (final block in content) {
        if (block is TextContent) buf.write(block.text);
      }
      final joined = buf.toString();
      return joined.isEmpty ? null : joined;
    default:
      return null;
  }
}

String? _toolNameOf(Object content) {
  if (content is! List) return null;
  for (final block in content) {
    if (block is ToolCall && block.name.isNotEmpty) return block.name;
  }
  return null;
}

/// Hands user input to the session's owning process through the agent
/// messaging fabric: an [AgentMessageKind.user] envelope addressed to the
/// session's `main` mailbox. The CLI's inbox watcher wakes and delivers
/// it as a user turn.
final class FileSessionInputChannel implements SessionInputChannel {
  /// Creates the channel over the fabric at [messagingRoot].
  FileSessionInputChannel({required FileMessagingRepository repository})
    : _repository = repository;

  final FileMessagingRepository _repository;

  @override
  Future<void> send(String sessionId, String text) async {
    // Absolute cross-instance address: `<sessionId>/main`.
    await _repository.send(
      AgentMessage(
        id: newMessageId(),
        fromId: 'app',
        toId: '$sessionId/main',
        text: text,
        sentAt: DateTime.now().toUtc().toIso8601String(),
        kind: AgentMessageKind.user,
      ),
    );
  }
}
