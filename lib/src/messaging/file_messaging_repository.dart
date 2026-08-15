/// File-backed [MessagingRepository] over an [ExecutionEnv]: every agent id
/// owns `<root>/<agent>/inbox/*.json` (unread) and `<root>/<agent>/read/`
/// (consumed). Two Fa instances sharing one root (e.g. the session repo of
/// one project) exchange messages through the filesystem — no live process
/// coupling needed.
library;

import 'dart:convert';

import '../env/execution_env.dart';
import 'agent_message.dart';
import 'messaging_repository.dart';

/// File-based messaging repository. Layout:
///
/// ```
/// <root>/<agentId>/inbox/<timestamp>_<rand>.json   (unread, name-ordered)
/// <root>/<agentId>/read/<timestamp>_<rand>.json    (consumed)
/// ```
///
/// Message file names start with a UTC timestamp prefix so directory order
/// is arrival order. Agent ids are sanitized for filesystem safety.
final class FileMessagingRepository implements MessagingRepository {
  FileMessagingRepository({required ExecutionEnv env, required String root})
    : _env = env,
      _root = root;

  final ExecutionEnv _env;
  final String _root;

  static final _unsafeChars = RegExp(r'[^a-zA-Z0-9._-]');

  /// Filesystem-safe directory name for an agent id (`explore:a1` →
  /// `explore_a1`).
  static String sanitizeAgentId(String agentId) =>
      agentId.replaceAll(_unsafeChars, '_');

  String _inboxDir(String agentId) =>
      '$_root/${sanitizeAgentId(agentId)}/inbox';
  String _readDir(String agentId) => '$_root/${sanitizeAgentId(agentId)}/read';

  @override
  Future<void> send(AgentMessage message) async {
    final dir = _inboxDir(message.toId);
    (await _env.createDir(dir)).getOrThrow();
    final path = '$dir/${_fileName(message)}';
    (await _env.writeFile(path, jsonEncode(message.toJson()))).getOrThrow();
  }

  @override
  Future<List<AgentMessage>> peek(String agentId) async =>
      _readAll(_inboxDir(agentId));

  @override
  Future<List<AgentMessage>> drain(String agentId) async {
    final inbox = _inboxDir(agentId);
    final messages = await _readAll(inbox);
    if (messages.isEmpty) return messages;
    (await _env.createDir(_readDir(agentId))).getOrThrow();
    for (var i = 0; i < messages.length; i++) {
      final file = _fileName(messages[i]);
      (await _env.writeFile(
        '${_readDir(agentId)}/$file',
        jsonEncode(messages[i].toJson()),
      )).getOrThrow();
      (await _env.remove('$inbox/$file', force: true)).getOrThrow();
    }
    return messages;
  }

  @override
  Future<List<String>> directory() async {
    final result = await _env.listDir(_root);
    final entries = result.valueOrNull;
    if (entries == null) return const [];
    return [
      for (final entry in entries)
        if (entry.kind == FileKind.directory) entry.name,
    ];
  }

  /// Deterministic, collision-resistant file name: the message id already
  /// carries a timestamp + random suffix (see [newMessageId]).
  String _fileName(AgentMessage message) => '${message.id}.json';

  Future<List<AgentMessage>> _readAll(String dir) async {
    final result = await _env.listDir(dir);
    final entries = result.valueOrNull;
    if (entries == null) return const [];
    final files = [
      for (final entry in entries)
        if (entry.kind == FileKind.file && entry.name.endsWith('.json'))
          entry.path,
    ]..sort();
    final messages = <AgentMessage>[];
    for (final path in files) {
      final text = (await _env.readTextFile(path)).valueOrNull;
      if (text == null) continue;
      try {
        messages.add(
          AgentMessage.fromJson(jsonDecode(text) as Map<String, dynamic>),
        );
      } on FormatException {
        // A torn write never poisons the inbox — skip the file.
      }
    }
    return messages;
  }
}
