// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The user's "High-quality image previews" choice (issue #207), persisted
/// as JSON at `image_preview.json` in the root of the sandbox filesystem
/// ([ExecutionEnv.cwd]) — the same envelope pattern as `chat_text.json`
/// (see [ChatTextStore]), so the choice survives app restarts.
///
/// Attached-image chat previews decode at a downscaled `cacheWidth` by
/// default (600px — a memory/display optimization; the stored and sent
/// bytes are always full fidelity). When [highQuality] is on, the previews
/// decode at full resolution instead.
///
/// The store is a [ChangeNotifier]: the settings switch edits it live and
/// every open transcript re-renders at the new decode constraint without a
/// restart. Writes are fire-and-forget best effort; a
/// missing/unreadable/corrupt file loads as the default (downscale ON).
class ImagePreviewStore extends ChangeNotifier {
  ImagePreviewStore(this._env);

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'image_preview.json';

  /// Schema version of the JSON envelope; other versions load as default.
  static const _version = 1;

  final ExecutionEnv _env;

  bool _highQuality = false;

  /// Whether attached-image previews decode at full resolution. Default
  /// `false` — the long-standing downscaled (600px) preview behavior.
  bool get highQuality => _highQuality;

  /// Loads the persisted choice; corrupt or missing data keeps the default.
  Future<void> load() async {
    try {
      final text = (await _env.readTextFile(
        '${_env.cwd}/$fileName',
      )).valueOrNull;
      if (text == null) return;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['version'] != _version) return;
      final highQuality = decoded['highQuality'];
      if (highQuality is bool) {
        _highQuality = highQuality;
        notifyListeners();
      }
    } on Object {
      // Corrupt or incompatible file → default, never crash boot.
    }
  }

  /// Sets and persists the choice; a no-op when the value is unchanged.
  void setHighQuality(bool highQuality) {
    if (highQuality == _highQuality) return;
    _highQuality = highQuality;
    notifyListeners();
    _save();
  }

  Future<void> _save() async {
    try {
      await _env.writeFile(
        '${_env.cwd}/$fileName',
        jsonEncode({'version': _version, 'highQuality': _highQuality}),
      );
    } on Object {
      // Persistence must never break the settings UI.
    }
  }
}

/// Provides the shared [ImagePreviewStore] down the tree; the settings
/// screen and the chat surface read it via [ImagePreviewScope.maybeOf] so
/// no constructor plumbing is needed through the launcher/settings layers.
class ImagePreviewScope extends InheritedNotifier<ImagePreviewStore> {
  const ImagePreviewScope({
    super.key,
    required ImagePreviewStore store,
    required super.child,
  }) : super(notifier: store);

  /// The nearest store, or null outside the app shell (tests pumping bare
  /// widgets keep the default downscaled previews).
  static ImagePreviewStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ImagePreviewScope>()?.notifier;
}
