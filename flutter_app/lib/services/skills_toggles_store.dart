// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The user's per-skill enable/disable toggles (issue #1151), persisted as
/// JSON at `skills_toggles.json` in the root of the sandbox filesystem
/// ([ExecutionEnv.cwd]) — same tiny-store pattern as `skills_access.json`
/// (see [SkillsAccessStore]).
///
/// The app has no `~/.fah/config.yaml`: this store is the single app-side
/// source for the per-skill `skills: {<name>: on|off}` wishes the CLI keeps
/// in yaml. A missing/unreadable/corrupt file loads as `{}` — every skill
/// default-on. Non-secret by design.
class SkillsTogglesStore {
  SkillsTogglesStore(this._env);

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'skills_toggles.json';

  /// Schema version of the JSON envelope; other versions load as `{}`.
  static const _version = 1;

  final ExecutionEnv _env;

  /// Loads the persisted wishes; `{}` when nothing valid is stored.
  Future<Map<String, bool>> load() async {
    try {
      final text = (await _env.readTextFile(
        '${_env.cwd}/$fileName',
      )).valueOrNull;
      if (text == null) return const {};
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return const {};
      if (decoded['version'] != _version) return const {};
      final toggles = decoded['toggles'];
      if (toggles is! Map) return const {};
      return {
        for (final entry in toggles.entries)
          if (entry.value is bool) '${entry.key}': entry.value as bool,
      };
    } on Object {
      // Corrupt or incompatible file → default-on, never crash boot.
      return const {};
    }
  }

  /// Persists [toggles]; best effort — a failed write must not break the
  /// settings UI or boot.
  Future<void> save(Map<String, bool> toggles) async {
    try {
      await _env.writeFile(
        '${_env.cwd}/$fileName',
        jsonEncode({'version': _version, 'toggles': toggles}),
      );
    } on Object {
      // Best effort.
    }
  }
}
