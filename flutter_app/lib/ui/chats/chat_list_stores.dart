import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'chat_list_entry.dart';

/// Per-account local pin choices. Network auth is optional: the local account
/// uses the stable `local` scope and remains fully usable while logged out.
final class ChatPinStore extends ChangeNotifier {
  ChatPinStore._(this._env, this.accountId, this._accounts);

  ChatPinStore.inMemory({required this.accountId, Set<String>? pinned})
    : _env = null,
      _accounts = {
        accountId: {...?pinned},
      };

  static const fileName = 'chat_list_pins.json';
  static const _version = 1;

  final ExecutionEnv? _env;
  final String accountId;
  final Map<String, Set<String>> _accounts;

  Set<String> get _pins => _accounts.putIfAbsent(accountId, () => <String>{});

  bool isPinned(ChatEntryId id) => _pins.contains(id.canonical);

  static Future<ChatPinStore> load(
    ExecutionEnv env, {
    required String accountId,
  }) async {
    final accounts = <String, Set<String>>{};
    try {
      final text = (await env.readTextFile('${env.cwd}/$fileName')).valueOrNull;
      if (text != null) {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic> &&
            decoded['version'] == _version &&
            decoded['accounts'] is Map) {
          for (final entry in (decoded['accounts'] as Map).entries) {
            if (entry.key is! String || entry.value is! List) continue;
            accounts[entry.key as String] = {
              for (final id in entry.value as List)
                if (id is String && id.isNotEmpty) id,
            };
          }
        }
      }
    } on Object {
      // A missing/corrupt preference file never blocks local chats.
    }
    return ChatPinStore._(env, accountId, accounts);
  }

  Future<void> setPinned(ChatEntryId id, bool value) async {
    final changed = value
        ? _pins.add(id.canonical)
        : _pins.remove(id.canonical);
    if (!changed) return;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    final env = _env;
    if (env == null) return;
    try {
      await env.writeFile(
        '${env.cwd}/$fileName',
        jsonEncode({
          'version': _version,
          'accounts': {
            for (final entry in _accounts.entries)
              entry.key: entry.value.toList()..sort(),
          },
        }),
      );
    } on Object {
      // Persistence is best effort; the in-memory action still succeeds.
    }
  }
}

/// Per-account monotonic read cursors.
///
/// Local cursors are transcript message counts. The network aggregate owns
/// server-side channel cursors; its adapter exposes the matching PATCH seam.
final class ChatReadCursorStore extends ChangeNotifier {
  ChatReadCursorStore._(this._env, this.accountId, this._accounts);

  ChatReadCursorStore.inMemory({
    required this.accountId,
    Map<String, int>? cursors,
  }) : _env = null,
       _accounts = {
         accountId: {...?cursors},
       };

  static const fileName = 'chat_read_cursors.json';
  static const _version = 1;

  final ExecutionEnv? _env;
  final String accountId;
  final Map<String, Map<String, int>> _accounts;

  Map<String, int> get _cursors =>
      _accounts.putIfAbsent(accountId, () => <String, int>{});

  int? cursorFor(ChatEntryId id) => _cursors[id.canonical];

  static Future<ChatReadCursorStore> load(
    ExecutionEnv env, {
    required String accountId,
  }) async {
    final accounts = <String, Map<String, int>>{};
    try {
      final text = (await env.readTextFile('${env.cwd}/$fileName')).valueOrNull;
      if (text != null) {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic> &&
            decoded['version'] == _version &&
            decoded['accounts'] is Map) {
          for (final account in (decoded['accounts'] as Map).entries) {
            if (account.key is! String || account.value is! Map) continue;
            accounts[account.key as String] = {
              for (final cursor in (account.value as Map).entries)
                if (cursor.key is String &&
                    cursor.value is num &&
                    cursor.value >= 0)
                  cursor.key as String: (cursor.value as num).toInt(),
            };
          }
        }
      }
    } on Object {
      // Corrupt preferences degrade to no local cursor (hence no fake unread).
    }
    return ChatReadCursorStore._(env, accountId, accounts);
  }

  /// Advances [id] to [cursor]. Older reads are ignored, including after a
  /// reload, so a slow open cannot resurrect cleared unread state.
  Future<void> markRead(ChatEntryId id, int cursor) async {
    if (cursor < 0 || (_cursors[id.canonical] ?? -1) >= cursor) return;
    _cursors[id.canonical] = cursor;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    final env = _env;
    if (env == null) return;
    try {
      await env.writeFile(
        '${env.cwd}/$fileName',
        jsonEncode({'version': _version, 'accounts': _accounts}),
      );
    } on Object {
      // Persistence is best effort; monotonicity still holds in memory.
    }
  }
}
