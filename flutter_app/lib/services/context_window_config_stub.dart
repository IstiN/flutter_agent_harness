// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web stub: no `~/.fah/config.yaml` on the browser platform — the
/// context-window settings surface renders its "not supported on this
/// platform" note (the compaction-engine loader's E2 contract).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'context_window_config.dart';

/// The effective owner cap: the stub has no config to read — uncapped.
AppContextCapResolution resolveAppContextWindowCap({
  String? projectDir,
  String? homeDir,
}) => const AppContextCapResolution(null, AppContextCapSource.none);

/// Whether this platform can persist context-window settings at all
/// (web: no yaml config layers).
const bool appContextWindowConfigSupported = false;

/// Writes (or clears) the owner cap: unsupported on web.
Future<String> writeAppContextWindowCap(
  int? value, {
  required AppContextCapSource layer,
  String? projectDir,
  String? homeDir,
}) async =>
    throw UnsupportedError('context-window config is not supported on web');

/// The per-model window override: the stub reads no config — none pinned.
int? loadAppModelWindowOverride(
  String provider,
  String modelId, {
  String? homeDir,
}) => null;

/// The whole parsed `models.overrides` layer: none on web.
ModelCapabilityOverrides? loadAppCapabilityOverrides({String? homeDir}) => null;

/// Writes (or clears) the per-model window override: unsupported on web.
Future<String> writeAppModelWindowOverride(
  String provider,
  String modelId,
  int? window, {
  String? homeDir,
}) async =>
    throw UnsupportedError('context-window config is not supported on web');
