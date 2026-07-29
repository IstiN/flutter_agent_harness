// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Whether the first-launch onboarding flow has been shown, persisted as JSON
/// at `onboarding_seen.json` in the root of the sandbox filesystem
/// ([ExecutionEnv.cwd]) — same tiny-store pattern as `theme.json` (see
/// [ThemeController]).
///
/// Read once at boot by `BootstrapScreen`: onboarding shows only when the
/// flag is false AND there is no restorable last connection (upgraders skip
/// it). Completing or skipping the flow calls [markSeen]; a missing,
/// unreadable, or corrupt file loads as unseen. Non-secret by design.
class OnboardingStore {
  OnboardingStore._(this._env, this._seen);

  /// A store without persistence (tests): [markSeen] flips [seen] in memory
  /// but nothing is written anywhere.
  OnboardingStore.inMemory({this._seen = false}) : _env = null;

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'onboarding_seen.json';

  /// Schema version of the JSON envelope; other versions load as unseen.
  static const _version = 1;

  final ExecutionEnv? _env;
  bool _seen;

  /// Loads the flag persisted in [env]; a missing, unreadable, or corrupt
  /// file yields unseen (the onboarding shows).
  static Future<OnboardingStore> load(ExecutionEnv env) async {
    var seen = false;
    try {
      final text = (await env.readTextFile('${env.cwd}/$fileName')).valueOrNull;
      if (text != null) {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic> && decoded['version'] == _version) {
          seen = decoded['seen'] == true;
        }
      }
    } on Object {
      // Corrupt or incompatible file → unseen, never crash boot.
    }
    return OnboardingStore._(env, seen);
  }

  /// Whether the onboarding flow has already been shown.
  bool get seen => _seen;

  /// Marks the onboarding as shown and persists it. Persistence is best
  /// effort: a failed write must not block the boot flow.
  Future<void> markSeen() async {
    if (_seen) return;
    _seen = true;
    final env = _env;
    if (env == null) return;
    try {
      await env.writeFile(
        '${env.cwd}/$fileName',
        jsonEncode({'version': _version, 'seen': true}),
      );
    } on Object {
      // Best effort: persistence must never block boot.
    }
  }
}
