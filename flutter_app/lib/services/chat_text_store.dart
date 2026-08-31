// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The user's chat text size, persisted as JSON at `chat_text.json` in the
/// root of the sandbox filesystem ([ExecutionEnv.cwd]) — the same envelope
/// pattern as `approval_mode.json` (see [ApprovalModeStore]), so the
/// choice survives app restarts.
///
/// The store is a [ChangeNotifier]: the settings slider edits it live and
/// every open transcript re-renders at the new size without a restart.
/// Writes are fire-and-forget best effort; a missing/unreadable/corrupt
/// file loads as the default size.
class ChatTextStore extends ChangeNotifier {
  ChatTextStore(this._env);

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'chat_text.json';

  /// Schema version of the JSON envelope; other versions load as default.
  static const _version = 1;

  /// Default chat body size in logical pixels.
  static const defaultFontSize = 14.0;

  /// The slider bounds.
  static const minFontSize = 12.0;
  static const maxFontSize = 20.0;

  final ExecutionEnv _env;

  double _fontSize = defaultFontSize;

  /// The current chat body size (always within
  /// [minFontSize]..[maxFontSize]).
  double get fontSize => _fontSize;

  /// Loads the persisted size; corrupt or missing data keeps the default.
  Future<void> load() async {
    try {
      final text = (await _env.readTextFile(
        '${_env.cwd}/$fileName',
      )).valueOrNull;
      if (text == null) return;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['version'] != _version) return;
      final size = decoded['fontSize'];
      if (size is num) {
        _fontSize = _clamp(size.toDouble());
        notifyListeners();
      }
    } on Object {
      // Corrupt or incompatible file → default size, never crash boot.
    }
  }

  /// Sets and persists the size (clamped to the slider bounds); a no-op
  /// when the clamped value is unchanged.
  void setFontSize(double size) {
    final clamped = _clamp(size);
    if (clamped == _fontSize) return;
    _fontSize = clamped;
    notifyListeners();
    _save();
  }

  double _clamp(double size) =>
      size.clamp(minFontSize, maxFontSize).toDouble();

  Future<void> _save() async {
    try {
      await _env.writeFile(
        '${_env.cwd}/$fileName',
        jsonEncode({'version': _version, 'fontSize': _fontSize}),
      );
    } on Object {
      // Persistence must never break the settings UI.
    }
  }
}

/// Provides the shared [ChatTextStore] down the tree; the settings screen
/// and the transcript surfaces read it via [ChatTextScope.maybeOf] so no
/// constructor plumbing is needed through the launcher/settings layers.
class ChatTextScope extends InheritedNotifier<ChatTextStore> {
  const ChatTextScope({
    super.key,
    required ChatTextStore store,
    required super.child,
  }) : super(notifier: store);

  /// The nearest store, or null outside the app shell (tests pumping bare
  /// widgets keep the default tile size).
  static ChatTextStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatTextScope>()?.notifier;
}
