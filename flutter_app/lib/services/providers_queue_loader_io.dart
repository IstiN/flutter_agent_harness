// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// IO implementation: the real three-scope queue resolution and the
/// surgical yaml upsert for the app editor (issue #418). Mirrors the CLI
/// editor's write (`/providers queue add|remove|move`) so both surfaces
/// produce the same file shape: a `providersQueue:` JSON block, written
/// only after the REAL parser accepts the edited whole section.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:yaml/yaml.dart';

import '../sandbox/env_factory_io.dart' show desktopHomeDir;

/// Whether this platform can persist the queue (IO: yes — the yaml
/// layers exist; the web stub answers false).
const bool appProviderQueueConfigSupported = true;

ProviderQueueResolution resolveAppProviderQueue({
  String? projectDir,
  String? homeDir,
}) {
  final resolvedHome = homeDir ?? desktopHomeDir();
  if (resolvedHome == null && projectDir == null) {
    return const ProviderQueueResolution(
      scope: ProviderQueueScope.user,
      entries: [],
      notices: [],
    );
  }
  final envText = io.Platform.environment['FA_PROVIDERS_QUEUE'];
  try {
    return resolveProviderQueueScopes([
      ProviderQueueScopeInput(
        scope: ProviderQueueScope.env,
        isPresent: envText != null && envText.trim().isNotEmpty,
        parse: envText == null ? null : parseProviderQueueEnv(envText),
      ),
      if (projectDir != null)
        ?_queueScopeFromFile(
          ProviderQueueScope.project,
          '$projectDir/.fah/config.yaml',
        ),
      if (resolvedHome != null)
        ?_queueScopeFromFile(
          ProviderQueueScope.user,
          '$resolvedHome/.fah/config.yaml',
        ),
    ]);
  } on Object {
    return const ProviderQueueResolution(
      scope: ProviderQueueScope.user,
      entries: [],
      notices: [],
    );
  }
}

/// Reads one yaml scope file into a queue scope input; a missing or
/// unreadable file is an absent scope (the boot treats it the same).
ProviderQueueScopeInput? _queueScopeFromFile(
  ProviderQueueScope scope,
  String path,
) {
  final file = io.File(path);
  if (!file.existsSync()) return null;
  String body;
  try {
    body = file.readAsStringSync();
  } on Object {
    return null;
  }
  final Object? doc;
  try {
    doc = loadYaml(body);
  } on Object {
    return null;
  }
  if (doc is! YamlMap) return null;
  final node = doc['providersQueue'];
  if (node == null) return null;
  return ProviderQueueScopeInput(
    scope: scope,
    isPresent: true,
    parse: parseProviderQueueYaml(node, source: path),
  );
}

Future<String> writeAppProviderQueue(
  List<ProviderQueueEntry> entries, {
  required ProviderQueueScope layer,
  String? projectDir,
  String? homeDir,
}) async {
  _assertFileQueueScope(layer);
  final path = appQueueConfigPath(
    layer,
    projectDir: projectDir,
    homeDir: homeDir,
  );
  assertQueueEnvNotSet();
  final file = io.File(path);
  final edited = editedQueueYaml(
    file.existsSync() ? file.readAsStringSync() : '',
    entries,
  );
  // Never persist a file the next boot would reject: the WHOLE edited
  // section re-parses with the real parser before the write.
  assertQueueParses(edited, path);
  if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
  await file.writeAsString(edited);
  return path;
}

/// The env scope has no file behind it (the boot reads FA_PROVIDERS_QUEUE).
void _assertFileQueueScope(ProviderQueueScope layer) {
  if (layer == ProviderQueueScope.env) {
    throw StateError(
      'FA_PROVIDERS_QUEUE is read-only from the app — edit the project '
      'or user yaml instead',
    );
  }
}

/// The yaml path of [layer]'s config file; the env scope never gets here.
@visibleForTesting
String appQueueConfigPath(
  ProviderQueueScope layer, {
  String? projectDir,
  String? homeDir,
}) => layer == ProviderQueueScope.project
    ? _projectQueuePath(projectDir)
    : _homeQueuePath(homeDir ?? desktopHomeDir());

String _projectQueuePath(String? projectDir) => projectDir == null
    ? throw StateError('no session project directory')
    : '$projectDir/.fah/config.yaml';

String _homeQueuePath(String? resolvedHome) => resolvedHome == null
    ? throw StateError('no home directory on this host')
    : '$resolvedHome/.fah/config.yaml';

/// The env is not writable and always wins: refuse an edit that the next
/// boot would never read (env set -> file queues are shadowed).
@visibleForTesting
void assertQueueEnvNotSet([Map<String, String>? environment]) {
  if ((environment ?? io.Platform.environment)['FA_PROVIDERS_QUEUE']
          ?.trim()
          .isNotEmpty ==
      true) {
    throw StateError(
      'FA_PROVIDERS_QUEUE env wins over any file queue — edit the env '
      'value or unset it',
    );
  }
}

/// The edited yaml body: a `providersQueue:` JSON block upserted into the
/// current file source.
@visibleForTesting
String editedQueueYaml(String source, List<ProviderQueueEntry> entries) {
  final body = const JsonEncoder.withIndent(
    '  ',
  ).convert([for (final entry in entries) entry.toJson()]);
  return upsertYamlPath(source, const [
    'providersQueue',
  ], configLeafLines(body, depth: 0));
}

/// Re-parses the whole edited file with the real queue parser.
@visibleForTesting
void assertQueueParses(String edited, String path) {
  final doc = loadYaml(edited);
  parseProviderQueueYaml(
    doc is YamlMap ? doc['providersQueue'] : null,
    source: path,
  );
}
