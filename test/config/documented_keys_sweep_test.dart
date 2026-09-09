// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// AC8 (issue #29), the exhaustive sweep: every config key the
/// `fa-self-config` skill documents — with the example values the skill
/// itself shows — must round-trip through the real [ConfigService] the
/// `config` tool and `fa config` wrap. A documented key that cannot be
/// set (or read back) is a bug in the skill or the writer; this test pins
/// the whole documented surface, not a hand-picked list.
///
/// Complements `fa_self_config_accuracy_test.dart`, which pins that the
/// documented keys match the parsers; this one pins that they are all
/// WRITABLE end to end, and that no schema key is left undocumented.
library;

import 'dart:io';

import 'dart:convert';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/config/config_service.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _skillPath = '.fah/skills/fa-self-config/SKILL.md';

/// Converts a parsed yaml node to plain Dart for JSON encoding.
Object? _plain(Object? node) {
  if (node is YamlMap) {
    return <String, Object?>{
      for (final e in node.entries) e.key.toString(): _plain(e.value),
    };
  }
  if (node is YamlList) return node.map(_plain).toList();
  return node;
}

/// Walks a node into dotted leaves. Lists stop the walk — a list is set
/// whole (the writer renders it as a yaml block from JSON), so
/// `customProviders: [...]` is one settable key, not indexed entries.
void _walk(
  String prefix,
  Object? node,
  void Function(String path, Object? value) emit,
) {
  if (node is YamlMap) {
    for (final entry in node.entries) {
      final key = entry.key.toString();
      _walk(prefix.isEmpty ? key : '$prefix.$key', entry.value, emit);
    }
    return;
  }
  emit(prefix, node is YamlScalar ? node.value : node);
}

/// Every ```yaml fence in the skill, parsed.
List<YamlMap> _documentedFences(String skill) {
  final fences = <YamlMap>[];
  final fence = RegExp(r'```yaml\n(.*?)```', dotAll: true);
  for (final match in fence.allMatches(skill)) {
    final doc = loadYaml(match.group(1)!);
    if (doc is YamlMap) fences.add(doc);
  }
  return fences;
}

void main() {
  final skill = File(_skillPath).readAsStringSync();
  final fences = _documentedFences(skill);
  final documentedTopLevel = <String>{
    for (final fence in fences) ...fence.keys.map((k) => k.toString()),
  };

  test('the skill actually documents yaml config sections (sanity)', () {
    expect(fences, isNotEmpty);
    expect(documentedTopLevel, contains('memory'));
  });

  test('every documented key round-trips through the real service', () async {
    final failures = <String>[];
    for (var i = 0; i < fences.length; i++) {
      final fence = fences[i];
      // Per-fence files: the fence IS the documented config shape.
      final home = await Directory.systemTemp.createTemp('ac8_home');
      final project = await Directory.systemTemp.createTemp('ac8_project');
      try {
        final env = LocalExecutionEnv(cwd: project.path);
        final service = ConfigService(env: env, homeDir: home.path);

        // Whole documented sections first: strict validators judge the
        // whole file, and some sections are only valid together (retry
        // needs roles; a models entry needs its siblings) — the skill
        // shows them as complete sections and so must the writer take
        // them.
        for (final entry in fence.entries) {
          final section = entry.key.toString();
          final json = jsonEncode(_plain(entry.value));
          try {
            await service.set(section, json);
          } on Object catch (e) {
            failures.add('fence $i section "$section": $e');
          }
        }

        // Then every documented leaf: set, read back, same value.
        final leaves = <String, Object?>{};
        for (final entry in fence.entries) {
          _walk(
            entry.key.toString(),
            entry.value,
            (path, value) => leaves.putIfAbsent(path, () => value),
          );
        }
        for (final leaf in leaves.entries) {
          final value = leaf.value;
          final literal = value is String ? value : jsonEncode(_plain(value));
          try {
            final setResult = await service.set(leaf.key, literal);
            final get = await service.get(leaf.key);
            // get() renders the PARSED value (scalars verbatim, lists
            // compact JSON) — compare against the documented value, not
            // the quoting of the written literal.
            final expected = value is String
                ? value
                : jsonEncode(_plain(value));
            if (!get.found) {
              failures.add('fence $i ${leaf.key}: not found after set');
            } else if (get.display != expected) {
              failures.add(
                'fence $i ${leaf.key}: set $literal, '
                'get back ${get.display} (want $expected)',
              );
            }
          } on Object catch (e) {
            failures.add('fence $i ${leaf.key}: $e');
          }
        }
      } finally {
        home.deleteSync(recursive: true);
        project.deleteSync(recursive: true);
      }
    }
    expect(failures, isEmpty, reason: 'documented keys that fail');
  });

  test('no schema top-level key is left undocumented', () async {
    // The schema's top-level keys (private in cli_config.dart), discovered
    // through the real writer: an unknown top-level key is rejected with
    // the full valid list in the message.
    final home = await Directory.systemTemp.createTemp('ac8_home');
    final project = await Directory.systemTemp.createTemp('ac8_project');
    try {
      final env = LocalExecutionEnv(cwd: project.path);
      final service = ConfigService(env: env, homeDir: home.path);
      // An unknown top-level key throws on get (set only warns — unknown
      // keys ride along as dead config) with the full valid list.
      try {
        await service.get('__no_such_key__');
        fail('unknown key unexpectedly accepted');
      } on ConfigException catch (e) {
        final validKeys = RegExp(r'known top-level keys: (.*)\)')
            .firstMatch(e.message)!
            .group(1)!
            .split(',')
            .map((k) => k.trim())
            .toSet();
        expect(validKeys, isNotEmpty);
        // A schema key with zero documentation would be unconfigurable by
        // a skill-following agent — the sweep's completeness half.
        final undocumented = validKeys.difference(documentedTopLevel);
        expect(
          undocumented,
          isEmpty,
          reason: 'schema keys the skill never documents',
        );
        // And the reverse: the skill never documents an unknown key.
        expect(
          documentedTopLevel.difference(validKeys),
          isEmpty,
          reason: 'keys documented outside the schema',
        );
      }
    } finally {
      home.deleteSync(recursive: true);
      project.deleteSync(recursive: true);
    }
  });
}
