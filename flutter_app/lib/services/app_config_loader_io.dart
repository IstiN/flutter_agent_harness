// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// IO implementation (issue #1078): reads `~/.fah/config.yaml` plus the
/// project pair (`.fah/config.yaml`, `.fah/rules.yaml`) and hands the raw
/// documents to [parseAppConfigSections] — the CLI's own parsers, so both
/// hosts resolve identical sections (the parity guard pins this).
///
/// Degradation (E2): an absent config is silence (most app users have
/// none); an unreadable or malformed one degrades to a warning naming the
/// file — the app stores keep their values and boot never blocks.
/// Project scope is gated on a readable mount (OQ2): no home, no project
/// read either. Desktop-only by construction (AC7 scope): Android/iOS have
/// no user home ([desktopHomeDir] answers null) and degrade to silence.
///
/// The read is synchronous on the calling isolate — the established
/// pattern (memory_config_loader, compaction_engine_loader do the same):
/// the file is a few KB, read once per service creation, so blocking
/// longer than a frame is not realistic. If configs ever grow, move this
/// behind `Isolate.run` here, not in the callers.
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:yaml/yaml.dart';

import '../sandbox/env_factory_io.dart' show desktopHomeDir;

/// The `FA_PROVIDER_TIMEOUT_SECONDS` env value (issue #1036): read here,
/// behind the same conditional import as the config file, so the web stub
/// keeps its "no environment on this platform" contract. Function-typed so
/// tests can inject a value without mutating the process environment.
String? Function() faProviderTimeoutSecondsEnv = () =>
    Platform.environment['FA_PROVIDER_TIMEOUT_SECONDS'];

/// Reads and resolves the app-honored config sections; null when this
/// platform has no readable home (web-like sandboxes). [homeDir] and
/// [projectDir] override the lookups (tests).
AppFahSections? loadAppFahConfig({String? projectDir, String? homeDir}) {
  final resolvedHome = homeDir ?? desktopHomeDir();
  if (resolvedHome == null) return null;
  final warnings = <String>[];
  final userPath = '$resolvedHome/.fah/config.yaml';
  final userDoc = _readYaml(userPath, warnings);
  Object? projectDoc;
  Object? projectRulesDoc;
  String? projectConfigPath;
  String? projectRulesPath;
  // OQ2 (pinned): ship user scope first; the project layers are gated on
  // a readable mount — existsSync is the mount probe, and an unreadable
  // hit degrades to the named warning like any other (E2).
  if (projectDir != null) {
    projectConfigPath = '$projectDir/.fah/config.yaml';
    projectRulesPath = '$projectDir/.fah/rules.yaml';
    projectDoc = _readYaml(projectConfigPath, warnings);
    projectRulesDoc = _readYaml(projectRulesPath, warnings);
  }
  return parseAppConfigSections(
    userDoc: userDoc,
    projectDoc: projectDoc,
    projectRulesDoc: projectRulesDoc,
    userSource: userPath,
    projectSource: projectConfigPath ?? '.fah/config.yaml',
    projectRulesSource: projectRulesPath ?? '.fah/rules.yaml',
    envMode: Platform.environment['FA_AGENT_MODE'],
  );
}

/// Reads one yaml file: absent → null (silent); unreadable or malformed →
/// null plus a warning naming the file (AC7); the caller's app stores
/// keep their values either way (E2).
Object? _readYaml(String path, List<String> warnings) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final String text;
  try {
    text = file.readAsStringSync();
  } on Object catch (error) {
    warnings.add('cannot read $path: $error');
    return null;
  }
  try {
    return loadYaml(text);
  } on Object catch (error) {
    warnings.add('cannot parse $path: $error');
    return null;
  }
}

/// The app's owner context-window cap (`agent.contextWindowCap`, gh-1077):
/// project `.fah/config.yaml` wins over `~/.fah/config.yaml` — the same
/// chain the CLI honors — null when neither states one (uncapped). A
/// missing or unreadable config never blocks boot (E2: silence, like the
/// section loader above).
int? loadAppContextWindowCap([String? projectDir]) {
  try {
    if (projectDir != null) {
      final project = loadProjectContextWindowCap(projectDir);
      if (project != null) return project;
    }
    final home = desktopHomeDir();
    if (home == null) return null;
    return loadCliConfig(home).contextWindowCap;
  } on Object {
    return null;
  }
}
