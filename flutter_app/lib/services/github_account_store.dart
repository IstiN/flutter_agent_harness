// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:fa/services/session_keys_store.dart';

/// The connected GitHub account used for widget publishing (card
/// `goal/widget-publishing-github.md`, issue #35).
///
/// Thin lifecycle wrapper over [SessionKeysStore]: the token
/// ([tokenKey]) and the non-secret profile fields ([loginKey],
/// [avatarKey]) ride the SAME Keychain-backed persistence the agent keys
/// use, so iOS/macOS keep them out of the plaintext file and every surface
/// reads through one store. The token also joins the boot-time
/// [SecretRedactor] for free (AgentService merges the whole session-keys
/// store into the redactor secrets).
///
/// The GitHub keys are EXCLUDED from the agent-keys settings section (the
/// `FA_GITHUB_` prefix filter in `settings.dart`) — their UI lives in the
/// GitHub account section, which is the only writer.
class GithubAccountStore extends ChangeNotifier {
  GithubAccountStore({required this._keys}) {
    _keys.addListener(_onKeysChanged);
  }

  /// Session-keys entries holding the account. The token is the secret;
  /// login/avatar are display metadata kept next to it so one store covers
  /// the whole account record.
  static const tokenKey = 'FA_GITHUB_TOKEN';
  static const loginKey = 'FA_GITHUB_LOGIN';
  static const avatarKey = 'FA_GITHUB_AVATAR';

  /// Every store key owned by the GitHub account — the agent-keys settings
  /// section filters this prefix out (single management surface).
  static bool isGithubKey(String name) => name.startsWith('FA_GITHUB_');

  final SessionKeysStore _keys;

  /// The personal/device-flow token, or null when disconnected.
  String? get token {
    final value = _keys.valueOf(tokenKey);
    return (value == null || value.isEmpty) ? null : value;
  }

  /// The GitHub login of the connected account, or null.
  String? get login => _keys.valueOf(loginKey);

  /// The avatar URL (display metadata), or null.
  String? get avatarUrl => _keys.valueOf(avatarKey);

  /// Whether an account is connected (token present). A stale profile with
  /// no token reads as disconnected — the token is the truth.
  bool get isConnected => token != null;

  /// Connects an account: token + profile in one shot. Reconnecting
  /// OVERWRITES the same entries (rotation propagates without a restart —
  /// every reader goes through this store).
  Future<void> connect({
    required String token,
    required String login,
    String? avatarUrl,
  }) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(token, 'token', 'must not be empty');
    }
    await _keys.set(tokenKey, trimmed);
    await _keys.set(loginKey, login);
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      await _keys.set(avatarKey, avatarUrl);
    } else {
      await _keys.delete(avatarKey);
    }
    notifyListeners();
  }

  /// Disconnects: removes the token AND the profile (in-flight PRs stay on
  /// GitHub — only status polling stops).
  Future<void> disconnect() async {
    await _keys.delete(tokenKey);
    await _keys.delete(loginKey);
    await _keys.delete(avatarKey);
    notifyListeners();
  }

  void _onKeysChanged() => notifyListeners();

  @override
  void dispose() {
    _keys.removeListener(_onKeysChanged);
    super.dispose();
  }
}
