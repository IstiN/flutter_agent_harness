// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web stub (issue #287 AC5): there is no `~/.fah/config.yaml` to read on
/// the web and no yaml layer to write, so the loader reports the
/// STRUCTURED default with [AppCompactionEngineSource.fallback], the
/// picker is unsupported ([appCompactionConfigSupported] is false — the
/// Settings section renders disabled with a note), and writes throw
/// [UnsupportedError] instead of pretending to persist.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'compaction_engine_loader.dart';

/// The parsed `compaction.engine`, or null (absent — default structured).
CompactionEngine? loadAppCompactionEngine([String? projectDir]) => null;

/// Whether this platform can persist the engine choice at all (web: no —
/// there is no config yaml).
const bool appCompactionConfigSupported = false;

/// Always the structured fallback with no config source: web has no yaml
/// to read, so the default engine applies (issue #287 AC5).
AppCompactionEngineResolution resolveAppCompactionEngine({
  String? projectDir,
  String? homeDir,
}) => const AppCompactionEngineResolution(
  CompactionEngine.structured,
  AppCompactionEngineSource.fallback,
);

/// Web has no config file to write — refuse instead of pretending.
Future<String> writeAppCompactionEngine(
  CompactionEngine engine, {
  required AppCompactionEngineSource layer,
  String? projectDir,
  String? homeDir,
}) => throw UnsupportedError(
  'compaction.engine cannot be persisted on the web (no config yaml)',
);
