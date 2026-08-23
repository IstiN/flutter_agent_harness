// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Whether the third-party skills consent surfaces (the onboarding page,
/// the one-time boot dialog, the settings row) make sense on this platform.
/// Claude Code / Copilot / Codex are desktop tools — on mobile there are no
/// third-party skill directories to consent to, so the question is pure
/// noise there (discovery gating itself is unaffected: there is simply
/// nothing to find). Based on [defaultTargetPlatform] — not dart:io
/// `Platform` — so widget tests can flip it via
/// `debugDefaultTargetPlatformOverride`.
bool get skillsConsentSurfacesVisible =>
    defaultTargetPlatform != TargetPlatform.android &&
    defaultTargetPlatform != TargetPlatform.iOS;

/// The user's consent for discovering THIRD-PARTY agent skills
/// (`.claude/`, `.github/skills/`, `.codex/` — see `SkillsAccess` in the
/// core), persisted as JSON at `skills_access.json` in the root of the
/// sandbox filesystem ([ExecutionEnv.cwd]) — same tiny-store pattern as
/// `approval_mode.json` (see [ApprovalModeStore]).
///
/// `null` (missing/unreadable/corrupt file, or a persisted `ask` label)
/// means UNDECIDED: first-party roots (`.fah/skills`, `.agents/skills`)
/// are always read, third-party roots are skipped, and interactive hosts
/// (the onboarding page, the one-time boot dialog) may still ask. Only an
/// explicit `granted` enables third-party discovery. Non-secret by design.
class SkillsAccessStore {
  SkillsAccessStore(this._env);

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'skills_access.json';

  /// Schema version of the JSON envelope; other versions load as `null`.
  static const _version = 1;

  final ExecutionEnv _env;

  /// The persisted consent, or `null` when undecided (nothing valid stored,
  /// or the stored value is `ask` — an explicit "ask me later" is
  /// indistinguishable from "never asked", so the one-time prompt can
  /// still appear).
  Future<SkillsAccess?> load() async {
    try {
      final text = (await _env.readTextFile(
        '${_env.cwd}/$fileName',
      )).valueOrNull;
      if (text == null) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['version'] != _version) return null;
      final access = skillsAccessFromLabel(decoded['access'] as String?);
      return access == SkillsAccess.ask ? null : access;
    } on Object {
      // Corrupt or incompatible file → undecided, never crash boot.
      return null;
    }
  }

  /// Persists [access]; best effort — a failed write must not break the
  /// settings UI or the boot dialog.
  Future<void> save(SkillsAccess access) async {
    try {
      await _env.writeFile(
        '${_env.cwd}/$fileName',
        jsonEncode({'version': _version, 'access': skillsAccessLabel(access)}),
      );
    } on Object {
      // Best effort.
    }
  }
}
