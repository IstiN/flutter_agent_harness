// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The user's dismissal of the in-app Get banner (issue #691 AC4),
/// persisted as JSON at [fileName] in the root of the sandbox filesystem
/// ([ExecutionEnv.cwd]) — same envelope pattern as `approval_mode.json`
/// (see [ApprovalModeStore]), so the dismissal survives app restarts and
/// (on web) page reloads through the mirrored sandbox. A single writer
/// is assumed (the banner); writes are fire-and-forget best effort, a
/// missing/unreadable/corrupt file loads as "not dismissed".
class StoreBannerStore {
  StoreBannerStore(this._env);

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'store_banner.json';

  /// Schema version of the JSON envelope; other versions load as
  /// "not dismissed".
  static const _version = 1;

  final ExecutionEnv _env;

  /// Whether the user dismissed the banner, or false when nothing valid
  /// is stored.
  Future<bool> loadDismissed() async {
    try {
      final text = (await _env.readTextFile(
        '${_env.cwd}/$fileName',
      )).valueOrNull;
      if (text == null) return false;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return false;
      if (decoded['version'] != _version) return false;
      return decoded['dismissed'] == true;
    } on Object {
      return false;
    }
  }

  /// Persists the dismissal (best effort — a failed write means the
  /// banner may re-appear after the next restart, never a crash).
  Future<void> saveDismissed() async => _write(dismissed: true);

  Future<void> _write({required bool dismissed}) async {
    try {
      await _env.writeFile(
        '${_env.cwd}/$fileName',
        jsonEncode({'version': _version, 'dismissed': dismissed}),
      );
    } on Object {
      // Persistence is best effort by design (see the class doc).
    }
  }
}
