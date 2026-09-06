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
  Future<void> register(String agentId, {String? sessionName}) async {
    try {
      final agentDir = '$_root/${sanitizeAgentId(agentId)}';
      (await _env.createDir('$agentDir/inbox')).getOrThrow();
      await _writeHeartbeat(agentDir);
      final marker = '$agentDir/.id';
      if ((await _env.exists(marker)).valueOrNull != true) {
        (await _env.writeFile(marker, agentId)).getOrThrow();
      }
      final name = sessionName?.trim();
      if (name != null && name.isNotEmpty) {
        // Written unconditionally (not once like .id): sessions can be
        // renamed. The no-op guard below keeps concurrent boots safe.
        final nameMarker = '$agentDir/.name';
        final existingName = (await _env.readTextFile(
          nameMarker,
        )).valueOrNull?.trim();
        if (existingName != name) {
          (await _env.writeFile(nameMarker, name)).getOrThrow();
        }
      }
      await _recordRegistry(agentId, name: name);
    } on Object {
      // Best-effort registration; a failure must not break process startup.
    }
  }

  @override
  Future<void> touch(String agentId) async {
    try {
      final agentDir = '$_root/${sanitizeAgentId(agentId)}';
      (await _env.createDir(agentDir, recursive: true)).getOrThrow();
      await _writeHeartbeat(agentDir);
      final marker = '$agentDir/.id';
      if ((await _env.exists(marker)).valueOrNull != true) {
        (await _env.writeFile(marker, agentId)).getOrThrow();
      }
    } on Object {
      // Best-effort heartbeat; a failure must not break the caller's loop.
    }
  }

  /// The `.heartbeat` marker: its mtime is the mailbox's liveness signal for
  /// [directory]. Content is informational (epoch ms).
  Future<void> _writeHeartbeat(String agentDir) async {
    (await _env.writeFile(
      '$agentDir/.heartbeat',
      DateTime.now().millisecondsSinceEpoch.toString(),
    )).getOrThrow();
  }

  @override
  Future<void> send(AgentMessage message) async {
    // Cross-project routing: the recipient drains only ITS OWN cwd-slug
    // messages root, so a sender-rooted write into a foreign mailbox
    // silently vanishes (a peer fa in another project never sees it).
    // Resolve the mailbox's real root first: the messages-registry.json
    // slug map, then a broad scan of sibling slugs; unknown ids stay local.
    final root = await _resolveRecipientRoot(message.toId);
    final dir = '$root/${sanitizeAgentId(message.toId)}/inbox';
    (await _env.createDir(dir)).getOrThrow();
    final agentDir = '$root/${sanitizeAgentId(message.toId)}';
    // The real (unsanitized) id marker, so directory() can report
    // human-meaningful mailbox names instead of filesystem-safe ones.
    final marker = '$agentDir/.id';
    if ((await _env.exists(marker)).valueOrNull != true) {
      (await _env.writeFile(marker, message.toId)).getOrThrow();
    }
    final path = '$dir/${_fileName(message)}';
    (await _env.writeFile(path, jsonEncode(message.toJson()))).getOrThrow();
  }

  /// The messages root that actually backs [agentId]'s mailbox: a foreign
  /// cwd-slug root when the mailbox lives in another project (registry
  /// entry first, then a sibling-slug scan by `.id` marker), otherwise
  /// [_root].
  Future<String> _resolveRecipientRoot(String agentId) async {
    final sanitized = sanitizeAgentId(agentId);
    // Fast path: the best-effort registry maps agent id -> slug.
    final slug = await _registrySlugFor(agentId);
    if (slug != null) {
      final peer = '${_sessionRoot()}/$slug/messages';
      if (slug != _ownSlug &&
          (await _env.exists('$peer/$sanitized')).valueOrNull == true) {
        return peer;
      }
    }
    // Broad scan of sibling slugs (sends are rare; correctness first).
    final slugDirs =
        (await _env.listDir(_sessionRoot())).valueOrNull ?? const [];
    for (final slugDir in slugDirs) {
      if (slugDir.kind != FileKind.directory) continue;
      final peerMessages = '${slugDir.path}/messages';
      if (peerMessages == _root) continue;
      final marker = (await _env.readTextFile(
        '$peerMessages/$sanitized/.id',
      )).valueOrNull?.trim();
      if (marker == agentId) return peerMessages;
    }
    return _root;
  }

  Future<String?> _registrySlugFor(String agentId) async {
    final home = _homeDir;
    if (home == null || home.isEmpty) return null;
    final path = (await _env.joinPath([
      home,
      '.fah',
      'messages-registry.json',
    ])).getOrThrow();
    final existing = await _env.readTextFile(path);
    final text = existing.valueOrNull;
    if (text == null || text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      final entry = decoded[agentId];
      if (entry is Map<String, dynamic> && entry['slug'] is String) {
        return entry['slug'] as String;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// This repository's own cwd slug (the `<slug>` in
  /// `<sessionRoot>/<slug>/messages`).
  String get _ownSlug {
    final parts = _root.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length < 2) return '';
    return parts[parts.length - 2];
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
        // Reserved names are not agent mailboxes: dot-dirs are hidden
        // state, `_scheduled` is the delayed-message store.
        if (mbDir.name.startsWith('.') || mbDir.name.startsWith('_')) {
          continue;
        }
        final idMarker = (await _env.readTextFile(
          '${mbDir.path}/.id',
        )).valueOrNull?.trim();
        final id = (idMarker != null && idMarker.isNotEmpty)
            ? idMarker
            : mbDir.name;
        final nameMarker = (await _env.readTextFile(
          '${mbDir.path}/.name',
        )).valueOrNull?.trim();
        final cwd = _decodeSessionCwd?.call(slugDir.name);
        entries.add(
          MailboxEntry(
            id: id,
            name: (nameMarker != null && nameMarker.isNotEmpty)
                ? nameMarker
                : null,
            slug: _peerSlug(slugDir),
            cwd: cwd,
            lastActivity: await _lastActivity(mbDir.path),
          ),
        );
      }
    }
    return entries;
  }

  /// The newest dated file inside [mailboxDir]: the `.heartbeat` marker at
  /// the top level plus everything in `inbox/` and `read/`. The `.id`
  /// marker is identity (written once), not activity — ignored, and
  /// directory mtimes are ignored too (some [ExecutionEnv] impls report 0
  /// for directories). Null when the mailbox holds no dated files at all.
  Future<DateTime?> _lastActivity(String mailboxDir) async {
    var newestMs = -1;
    void consider(int mtimeMs) {
      if (mtimeMs > newestMs) newestMs = mtimeMs;
    }

    final top = (await _env.listDir(mailboxDir)).valueOrNull;
    if (top != null) {
      for (final item in top) {
        if (item.kind == FileKind.file && item.name == '.heartbeat') {
          consider(item.mtimeMs);
        }
      }
    }
    for (final sub in const ['inbox', 'read']) {
      final items = (await _env.listDir('$mailboxDir/$sub')).valueOrNull;
      if (items == null) continue;
      for (final item in items) {
        if (item.kind == FileKind.file) consider(item.mtimeMs);
      }
    }
    if (newestMs < 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(newestMs, isUtc: true);
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
  /// instance's mailboxes without scanning every slug directory. [name]
  /// (session display name) rides along when known so name-based addressing
  /// has a fast path.
  Future<void> _recordRegistry(String agentId, {String? name}) async {
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
    final entry = <String, dynamic>{'slug': slug, 'cwd': cwd};
    final trimmed = name?.trim();
    if (trimmed != null && trimmed.isNotEmpty) entry['name'] = trimmed;
    registry[agentId] = entry;
    final encoded = jsonEncode(registry);
    // No-op when the content is unchanged: two instances booting at once
    // would otherwise read-modify-write the same file concurrently and one
    // writer could tear the other's bytes mid-record.
    if (existingText == encoded) return;
    (await _env.writeFile(path, encoded)).getOrThrow();
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

/// Moves pending mail out of orphan mailboxes into [agentId]'s real inbox,
/// returning the number of messages moved. An orphan mailbox appears when
/// a sender addressed this agent with a truncated id (the short form
/// `agent_directory` displays, or an older binary without prefix
/// resolution): the send then created a fresh directory no watcher ever
/// polls (`01a060f2_main` for `01a060f2-7d4b-…_main`) — silent mail loss.
/// An orphan is a `<head>_main` directory whose head is a strict prefix of
/// [agentId]'s own id. Best-effort: a failing move leaves the orphan in
/// place; an emptied orphan directory is removed.
Future<int> reclaimOrphanMailboxMail({
  required ExecutionEnv env,
  required String root,
  required String agentId,
}) async {
  final self = FileMessagingRepository.sanitizeAgentId(agentId);
  const suffix = '_main';
  if (!self.endsWith(suffix)) return 0;
  final selfHead = self.substring(0, self.length - suffix.length);
  final listing = (await env.listDir(root)).valueOrNull ?? const [];
  var moved = 0;
  for (final dir in listing) {
    if (dir.kind != FileKind.directory) continue;
    final name = dir.path.split('/').last;
    if (name == self || !name.endsWith(suffix)) continue;
    final head = name.substring(0, name.length - suffix.length);
    if (head.isEmpty || !selfHead.startsWith(head)) continue;
    moved += await _moveInboxFiles(
      env,
      from: '${dir.path}/inbox',
      to: '$root/$self/inbox',
    );
    // Best-effort cleanup; a leftover empty orphan is harmless.
    await env.remove(dir.path, recursive: true, force: true);
  }
  return moved;
}

/// Moves every file from [from] into [to], renaming on filename collision
/// so no mail is ever dropped. Returns the number of files moved.
Future<int> _moveInboxFiles(
  ExecutionEnv env, {
  required String from,
  required String to,
}) async {
  final listing = (await env.listDir(from)).valueOrNull;
  if (listing == null) return 0;
  (await env.createDir(to)).getOrThrow();
  var moved = 0;
  for (final file in listing) {
    if (file.kind != FileKind.file) continue;
    final name = file.path.split('/').last;
    var target = '$to/$name';
    if ((await env.exists(target)).valueOrNull == true) {
      final dot = name.lastIndexOf('.');
      target = dot < 0
          ? '$to/${name}_orphan'
          : '$to/${name.substring(0, dot)}_orphan${name.substring(dot)}';
    }
    final text = (await env.readTextFile(file.path)).valueOrNull;
    if (text == null) continue;
    (await env.writeFile(target, text)).getOrThrow();
    (await env.remove(file.path, force: true)).getOrThrow();
    moved++;
  }
  return moved;
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
  Future<void> register(String agentId, {String? sessionName}) =>
      _inner.register(agentId, sessionName: sessionName);

  @override
  Future<void> touch(String agentId) => _inner.touch(agentId);

  @override
  Future<void> send(AgentMessage message) => _inner.send(message);

  @override
  Future<List<AgentMessage>> peek(String agentId) => _inner.peek(agentId);

  @override
  Future<List<AgentMessage>> drain(String agentId) => _inner.drain(agentId);

  @override
  Future<List<MailboxEntry>> directory() => _inner.directory();
}
