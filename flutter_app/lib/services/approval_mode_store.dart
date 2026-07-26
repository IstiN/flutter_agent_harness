// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The user's chosen tool-approval mode, persisted as JSON at
/// `approval_mode.json` in the root of the sandbox filesystem
/// ([ExecutionEnv.cwd]) — same envelope pattern as `session_keys.json`
/// (see `SessionKeysStore`), so the choice survives app restarts.
///
/// A single writer per service is assumed (the settings dialog); writes are
/// fire-and-forget best effort, a missing/unreadable/corrupt file loads as
/// `null` (the service then keeps its default mode).
class ApprovalModeStore {
  ApprovalModeStore(this._env);

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'approval_mode.json';

  /// Schema version of the JSON envelope; other versions load as `null`.
  static const _version = 1;

  final ExecutionEnv _env;

  /// The persisted mode, or `null` when nothing valid is stored.
  Future<ApprovalMode?> load() async {
    try {
      final text = (await _env.readTextFile(
        '${_env.cwd}/$fileName',
      )).valueOrNull;
      if (text == null) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['version'] != _version) return null;
      final mode = decoded['mode'];
      for (final value in ApprovalMode.values) {
        if (value.name == mode) return value;
      }
      return null;
    } on Object {
      // Corrupt or incompatible file → no persisted mode, never crash boot.
      return null;
    }
  }

  /// Persists [mode]; best effort — a failed write must not break the
  /// settings UI.
  Future<void> save(ApprovalMode mode) async {
    try {
      await _env.writeFile(
        '${_env.cwd}/$fileName',
        jsonEncode({'version': _version, 'mode': mode.name}),
      );
    } on Object {
      // Best effort.
    }
  }
}
