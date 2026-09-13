// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Resolves (and persists) the `compaction.engine` setting for the app —
/// the same global < project chain the CLI honors (issue #148 D8, default
/// flip #287): project `.fah/config.yaml` wins over `~/.fah/config.yaml`,
/// default structured (2.0; classic stays the explicit rollback).
/// IO platforms read the real config; the stub (web) reports the
/// structured default with no config source (web has no yaml).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

export 'compaction_engine_loader_stub.dart'
    if (dart.library.io) 'compaction_engine_loader_io.dart';

/// The config layer the effective engine came from (issue #287 AC2).
enum AppCompactionEngineSource {
  /// The project `.fah/config.yaml` (deepest scope; travels with the repo).
  project,

  /// The user `~/.fah/config.yaml`.
  user,

  /// No config stated a choice — the structured default applies.
  fallback,
}

/// The effective app compaction engine plus the layer it came from:
/// what the Settings picker shows next to the dropdown ("structured ·
/// project config", "classic · user config", "structured · default").
final class AppCompactionEngineResolution {
  const AppCompactionEngineResolution(this.engine, this.source);

  /// The engine a compaction run uses.
  final CompactionEngine engine;

  /// Where [engine] came from.
  final AppCompactionEngineSource source;
}
