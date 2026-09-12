// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Which surface owns the narrow-layout home: the conversation (the chat
/// sheet expanded over the apps grid — apps collapsed) or the apps grid
/// (chat collapsed to the pinned composer bar — apps expanded). Persisted
/// as JSON at `apps_home_mode.json` in the root of the sandbox filesystem
/// ([ExecutionEnv.cwd]) — same tiny-store pattern as `onboarding_seen.json`
/// (see [OnboardingStore]).
///
/// Written on every apps↔chat toggle (issue #224) and read once when the
/// [SessionChatSheet] mounts with restore enabled; a missing, unreadable,
/// or corrupt file loads as the issue default — chat expanded, the
/// conversation is the primary surface. Non-secret by design.
class AppsHomeModeStore {
  AppsHomeModeStore._(this._env, this._chatExpanded);

  /// A store without persistence (tests): [setChatExpanded] flips
  /// [chatExpanded] in memory but nothing is written anywhere. Defaults to
  /// apps-expanded — the launcher's historical resting state, which the
  /// golden and widget fixtures pin.
  AppsHomeModeStore.inMemory({this._chatExpanded = false}) : _env = null;

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'apps_home_mode.json';

  /// Schema version of the JSON envelope; other versions load as the
  /// default below.
  static const _version = 1;

  final ExecutionEnv? _env;
  bool _chatExpanded;

  /// Loads the mode persisted in [env]; a missing, unreadable, or corrupt
  /// file yields the first-run default (chat expanded — apps collapsed).
  static Future<AppsHomeModeStore> load(ExecutionEnv env) async {
    var chatExpanded = true;
    try {
      final text = (await env.readTextFile('${env.cwd}/$fileName')).valueOrNull;
      if (text != null) {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic> && decoded['version'] == _version) {
          chatExpanded = decoded['chatExpanded'] != false;
        }
      }
    } on Object {
      // Corrupt or incompatible file → the default, never crash boot.
    }
    return AppsHomeModeStore._(env, chatExpanded);
  }

  /// Whether the chat sheet boots expanded over the apps grid (apps
  /// collapsed).
  bool get chatExpanded => _chatExpanded;

  /// Records the mode after a toggle and persists it. Persistence is best
  /// effort: a failed write must never block the toggle animation.
  Future<void> setChatExpanded(bool value) async {
    _chatExpanded = value;
    final env = _env;
    if (env == null) return;
    try {
      await env.writeFile(
        '${env.cwd}/$fileName',
        jsonEncode({'version': _version, 'chatExpanded': value}),
      );
    } on Object {
      // Best effort: persistence must never block the UI.
    }
  }
}
