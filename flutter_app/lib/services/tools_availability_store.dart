// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The user's per-tool availability choices (issue #19), persisted as JSON
/// at `tools_availability.json` in the root of the sandbox filesystem
/// ([ExecutionEnv.cwd]) — same tiny-store pattern as `approval_mode.json`
/// (see [ApprovalModeStore]).
///
/// The `tools` envelope is [ToolsConfig.toJson] verbatim — the same format
/// the CLI parses — so the app's choices and a CLI config are
/// interchangeable. A missing/unreadable/corrupt file loads as `null` (the
/// service then keeps every wired tool enabled); writes are best-effort.
class ToolsAvailabilityStore {
  ToolsAvailabilityStore(this._env);

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'tools_availability.json';

  /// Schema version of the JSON envelope; other versions load as `null`.
  static const _version = 1;

  final ExecutionEnv _env;

  /// The persisted config, or `null` when nothing valid is stored.
  Future<ToolsConfig?> load() async {
    try {
      final text = (await _env.readTextFile(
        '${_env.cwd}/$fileName',
      )).valueOrNull;
      if (text == null) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['version'] != _version) return null;
      return ToolsConfig.fromJson(decoded);
    } on Object {
      // Corrupt or incompatible file → nothing stored, never crash boot.
      return null;
    }
  }

  /// Persists [config]; best effort — a failed write must not break the
  /// settings UI.
  Future<void> save(ToolsConfig config) async {
    try {
      await _env.writeFile(
        '${_env.cwd}/$fileName',
        jsonEncode({'version': _version, ...config.toJson()}),
      );
    } on Object {
      // Best effort.
    }
  }
}
