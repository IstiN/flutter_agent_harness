/// File-backed [MessagingRepository] over an [ExecutionEnv]: every agent id
/// owns `<root>/<agent>/inbox/*.json` (unread) and `<root>/<agent>/read/`
/// (consumed). Two Fa instances sharing one root (e.g. the session repo of
/// one project) exchange messages through the filesystem — no live process
/// coupling needed.
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import '../env/execution_env.dart';
import '../session/session_repo.dart';
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
  FileMessagingRepository({
    required ExecutionEnv env,
    required String root,
    String? homeDir,
    String? Function(String slug)? decodeSessionCwd,
  }) : _env = env,
       _root = root,
       _homeDir = homeDir,
       _decodeSessionCwd = decodeSessionCwd;

  final ExecutionEnv _env;
  final String _root;
  final String? _homeDir;
  final String? Function(String slug)? _decodeSessionCwd;

  static final _unsafeChars = RegExp(r'[^a-zA-Z0-9._-]');

  /// Filesystem-safe directory name for an agent id (`explore:a1` →
  /// `explore_a1`).
  static String sanitizeAgentId(String agentId) =>
      agentId.replaceAll(_unsafeChars, '_');

  String _inboxDir(String agentId) =>
      '$_root/${sanitizeAgentId(agentId)}/inbox';
  String _readDir(String agentId) => '$_root/${sanitizeAgentId(agentId)}/read';

  @override
  Future<void> register(String agentId) async {
    try {
      final agentDir = '$_root/${sanitizeAgentId(agentId)}';
      (await _env.createDir('$agentDir/inbox')).getOrThrow();
      final marker = '$agentDir/.id';
      if ((await _env.exists(marker)).valueOrNull != true) {
        (await _env.writeFile(marker, agentId)).getOrThrow();
      }
      await _recordRegistry(agentId);
    } on Object {
      // Best-effort registration; a failure must not break process startup.
    }
  }

  @override
  Future<void> send(AgentMessage message) async {
    final dir = _inboxDir(message.toId);
    (await _env.createDir(dir)).getOrThrow();
    final agentDir = '$_root/${sanitizeAgentId(message.toId)}';
    // The real (unsanitized) id marker, so directory() can report
    // human-meaningful mailbox names instead of filesystem-safe ones.
    final marker = '$agentDir/.id';
    if ((await _env.exists(marker)).valueOrNull != true) {
      (await _env.writeFile(marker, message.toId)).getOrThrow();
    }
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
  Future<List<MailboxEntry>> directory() async {
    final sessionRoot = _sessionRoot();
    final entries = <MailboxEntry>[];
    final slugDirs = (await _env.listDir(sessionRoot)).valueOrNull ?? const [];
    for (final slugDir in slugDirs) {
      if (slugDir.kind != FileKind.directory) continue;
      final messagesDir = _peerMessagesRoot(slugDir);
      final mbDirs = (await _env.listDir(messagesDir)).valueOrNull ?? const [];
      for (final mbDir in mbDirs) {
        if (mbDir.kind != FileKind.directory) continue;
        final idMarker = (await _env.readTextFile(
          '${mbDir.path}/.id',
        )).valueOrNull?.trim();
        final id = (idMarker != null && idMarker.isNotEmpty)
            ? idMarker
            : mbDir.name;
        final cwd = _decodeSessionCwd?.call(slugDir.name);
        entries.add(MailboxEntry(id: id, slug: _peerSlug(slugDir), cwd: cwd));
      }
    }
    return entries;
  }

  /// The session root that contains all `<slug>/messages` directories.
  String _sessionRoot() {
    final parts = _root.split('/').where((s) => s.isNotEmpty).toList();
    // _root is <sessionRoot>/<slug>/messages.
    if (parts.length < 2) return '/';
    return '/${parts.sublist(0, parts.length - 2).join('/')}';
  }

  /// The messages directory for a peer slug directory.
  String _peerMessagesRoot(FileInfo slugDir) => '${slugDir.path}/messages';

  /// The slug name for a peer slug directory.
  String _peerSlug(FileInfo slugDir) => slugDir.name;

  /// Best-effort registry write so tooling can look up cwd metadata for this
  /// instance's mailboxes without scanning every slug directory.
  Future<void> _recordRegistry(String agentId) async {
    final home = _homeDir;
    if (home == null || home.isEmpty) return;
    final slug = encodeSessionCwd(_env.cwd);
    final cwd = _decodeSessionCwd?.call(slug) ?? '';
    final path = (await _env.joinPath([
      home,
      '.fah',
      'messages-registry.json',
    ])).getOrThrow();
    var registry = <String, dynamic>{};
    final existing = await _env.readTextFile(path);
    final existingText = existing.valueOrNull;
    if (existingText != null && existingText.isNotEmpty) {
      try {
        final decoded = jsonDecode(existingText) as Map<String, dynamic>;
        registry = Map<String, dynamic>.from(decoded);
      } on FormatException {
        registry = {};
      }
    }
    registry[agentId] = {'slug': slug, 'cwd': cwd};
    (await _env.writeFile(path, jsonEncode(registry))).getOrThrow();
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

/// A [MessagingRepository] whose backing implementation can be replaced at
/// runtime. The CLI uses this so the agent messaging fabric can follow the
/// EFFECTIVE session root: when session creation falls back from the shared
/// root (macOS App Group) to `~/.fah/sessions`, the mailboxes must move with
/// it — a fabric pinned to the old root would let an attached app write into
/// inboxes no running process ever drains.
final class SwappableMessagingRepository implements MessagingRepository {
  SwappableMessagingRepository(MessagingRepository initial) : _inner = initial;

  MessagingRepository _inner;

  /// Atomically replaces the delegate repository. In-flight calls finish on
  /// their old delegate; every later call goes to [repo].
  void swap(MessagingRepository repo) => _inner = repo;

  @override
  Future<void> register(String agentId) => _inner.register(agentId);

  @override
  Future<void> send(AgentMessage message) => _inner.send(message);

  @override
  Future<List<AgentMessage>> peek(String agentId) => _inner.peek(agentId);

  @override
  Future<List<AgentMessage>> drain(String agentId) => _inner.drain(agentId);

  @override
  Future<List<MailboxEntry>> directory() => _inner.directory();
}
