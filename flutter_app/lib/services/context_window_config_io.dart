// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// IO implementation: reads and writes the SAME config keys the CLI does —
/// `agent.contextWindowCap` and
/// `models.overrides.<provider>.<modelId>.contextWindow` — through the
/// shared [ConfigService] machinery (set) and the same validated
/// surgical-edit semantics the CLI settings flows use (remove). Every
/// write validates the edited document with the real parsers BEFORE
/// persisting, so the next boot never rejects the file.
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:yaml/yaml.dart';

import '../sandbox/env_factory_io.dart' show desktopHomeDir;
import 'context_window_config.dart';

/// The effective owner cap (`agent.contextWindowCap`): project
/// `.fah/config.yaml` wins over `~/.fah/config.yaml` — the same chain the
/// CLI resolves through [resolveContextWindowCap]. Null = uncapped.
/// [homeDir] overrides the user-home lookup (tests inject a temp dir).
AppContextCapResolution resolveAppContextWindowCap({
  String? projectDir,
  String? homeDir,
}) {
  int? projectCap;
  if (projectDir != null) {
    projectCap = _guard(() => loadProjectContextWindowCap(projectDir));
    if (projectCap != null) {
      return AppContextCapResolution(projectCap, AppContextCapSource.project);
    }
  }
  final home = homeDir ?? desktopHomeDir();
  if (home != null) {
    final userCap = _guard(() => loadCliConfig(home).contextWindowCap);
    if (userCap != null) {
      return AppContextCapResolution(userCap, AppContextCapSource.user);
    }
  }
  return const AppContextCapResolution(null, AppContextCapSource.none);
}

/// Writes (or clears) the owner cap into [layer] — the surgical
/// validated edit through the core [ConfigService] (set) and its
/// `fa config`-equivalent remove semantics (clear). Returns the file path
/// that was edited. [homeDir] overrides the user-home lookup (tests).
Future<String> writeAppContextWindowCap(
  int? value, {
  required AppContextCapSource layer,
  String? projectDir,
  String? homeDir,
}) async {
  if (layer == AppContextCapSource.none) {
    throw ArgumentError('none is not a writable layer — pick project or user');
  }
  final home = homeDir ?? desktopHomeDir();
  if (layer == AppContextCapSource.user && home == null) {
    throw const ConfigException(
      'user config unavailable on this host (no home directory) — write '
      'the project layer instead',
    );
  }
  final project = layer == AppContextCapSource.project;
  final path = project
      ? '$projectDir/.fah/config.yaml'
      : '$home/.fah/config.yaml';
  if (value == null) {
    await _removeYamlKey(
      path,
      const ['agent', 'contextWindowCap'],
      validateSection: (doc) {
        final agent = doc['agent'];
        if (agent != null) validateAgentSection(agent);
      },
    );
    return path;
  }
  final env = LocalExecutionEnv(cwd: projectDir ?? home ?? '.');
  final service = ConfigService(env: env, homeDir: home);
  final result = await service.set(
    'agent.contextWindowCap',
    '$value',
    scope: project ? ConfigScope.project : ConfigScope.global,
  );
  return result.file;
}

/// The per-model window override pinned for (provider, modelId) in the
/// USER config (`models.overrides`) — the same layer the resolver's top
/// precedence reads and the CLI's model-caps flow writes. Null when
/// nothing is pinned (the chain decides). [homeDir] overrides the
/// user-home lookup (tests).
int? loadAppModelWindowOverride(
  String provider,
  String modelId, {
  String? homeDir,
}) {
  return loadAppCapabilityOverrides(
    homeDir: homeDir,
  )?.lookup(provider, modelId)?.contextWindow;
}

/// The whole parsed `models.overrides` layer from the USER config — what
/// the host installs process-wide so every model build resolves the same
/// pins. Null when no home exists or the config carries no overrides.
/// [homeDir] overrides the user-home lookup (tests).
ModelCapabilityOverrides? loadAppCapabilityOverrides({String? homeDir}) {
  final home = homeDir ?? desktopHomeDir();
  if (home == null) return null;
  return _guard(() => loadCliConfig(home).models?.overrides);
}

/// Writes (or clears) the per-model window override into the USER config
/// — the same path and validation the CLI's model-caps flow applies
/// (validated with the real [ModelsConfig] parser BEFORE the write; a
/// below-floor value throws the parser's verbatim [ConfigException] and
/// writes NOTHING). Returns the file path that was edited.
Future<String> writeAppModelWindowOverride(
  String provider,
  String modelId,
  int? window, {
  String? homeDir,
}) async {
  final home = homeDir ?? desktopHomeDir();
  if (home == null) {
    throw const ConfigException(
      'no home directory on this host — the user config is unavailable',
    );
  }
  final path = '$home/.fah/config.yaml';
  if (window != null && window < minOverrideContextWindow) {
    throw ConfigException(
      '"contextWindow" must be at least $minOverrideContextWindow — below '
      'the compaction reserve the summarizer can never keep up',
    );
  }
  final segments = ['models', 'overrides', provider, modelId, 'contextWindow'];
  if (window == null) {
    await _removeYamlKey(
      path,
      segments,
      validateSection: (doc) {
        final models = doc['models'];
        if (models != null) ModelsConfig.fromYaml(models);
      },
    );
    return path;
  }
  final source = _readTextOrNull(path) ?? '';
  final edited = upsertYamlPath(
    source,
    segments,
    configLeafLines('$window', depth: segments.length - 1),
  );
  _validateEdited(path, edited, (doc) {
    final models = doc['models'];
    if (models != null) ModelsConfig.fromYaml(models);
  });
  File(path).writeAsStringSync(edited);
  return path;
}

/// The surgical remove path shared by both clears (gh-2479): read →
/// `removeYamlPath` → validate the parsed document with [validateSection]
/// (only when the section survives) → write. An absent key removes
/// nothing (a no-op returning quietly, like the CLI's "already off").
Future<void> _removeYamlKey(
  String path,
  List<String> segments, {
  required void Function(YamlMap doc) validateSection,
}) async {
  final source = _readTextOrNull(path);
  if (source == null) return; // absent file — nothing to remove
  final edited = removeYamlPath(source, segments);
  if (edited == source) return; // key absent — already off
  _validateEdited(path, edited, validateSection);
  File(path).writeAsStringSync(edited);
}

/// Validates [edited] the way every config write must (the CLI's "not
/// saved" contract): parse with the real yaml loader, hand the document
/// to [validateSection]; a throw propagates BEFORE any bytes land.
void _validateEdited(
  String path,
  String edited,
  void Function(YamlMap doc) validateSection,
) {
  final Object? doc;
  try {
    doc = loadYaml(edited);
  } on Object catch (error) {
    throw ConfigException('cannot validate $path: $error');
  }
  if (doc is YamlMap) validateSection(doc);
}

String? _readTextOrNull(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    return file.readAsStringSync();
  } on Object {
    return null;
  }
}

/// Wraps a config read so an absent/unreadable layer never blocks the
/// settings surface (the loaders' degradation contract).
T? _guard<T>(T? Function() read) {
  try {
    return read();
  } on Object {
    return null;
  }
}
