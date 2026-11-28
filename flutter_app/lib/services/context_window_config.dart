// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Resolves (and persists) the context-window settings for the app
/// (gh-2479): the owner cap (`agent.contextWindowCap`) and the per-model
/// window overrides (`models.overrides.<provider>.<modelId>
/// .contextWindow`). The SAME config keys the CLI reads and writes
/// (single source of truth) — the app edits them through the shared
/// [ConfigService] machinery and the same validated surgical-edit
/// semantics, never an app-only fork.
///
/// IO platforms read/write the real config files; the stub (web) answers
/// "not supported" (web has no `~/.fah/config.yaml`).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

export 'context_window_config_stub.dart'
    if (dart.library.io) 'context_window_config_io.dart';

/// The config layer the effective owner cap came from (the
/// compaction-engine loader's source rule).
enum AppContextCapSource {
  /// The project `.fah/config.yaml` (deepest scope; travels with the repo).
  project,

  /// The user `~/.fah/config.yaml`.
  user,

  /// No config states a cap — the model window rides uncapped.
  none,
}

/// The effective owner cap plus the layer it came from: what the settings
/// picker shows next to the value ("200000 · project config",
/// "65536 · user config", "uncapped").
final class AppContextCapResolution {
  const AppContextCapResolution(this.cap, this.source);

  /// The owner cap, or null when uncapped.
  final int? cap;

  /// Where [cap] came from.
  final AppContextCapSource source;
}

/// Whether this platform can persist context-window settings at all
/// (IO: yes — the yaml config layers exist; the web stub answers false).
const bool appContextWindowConfigSupported = true;

/// The token floor of a per-model window override (the resolver's parse
/// floor — the compaction reserve).
const int appMinOverrideContextWindow = minOverrideContextWindow;
