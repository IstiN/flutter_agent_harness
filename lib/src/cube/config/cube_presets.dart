/// Built-in cube security levels: the `L1`–`L3` ladder crossed with the
/// application axis (`core` / `full`).
///
/// The levels answer "where may it touch the disk", the app axis answers
/// "which commands may it run":
///
/// - **L1** — reads and writes only the current folder; everything outside
///   is denied. Maximum protection.
/// - **L2** — reads everywhere (read-only mounts), writes only inside the
///   current folder.
/// - **L3** — reads and writes everywhere; the current folder is just the
///   working directory.
/// - **core** apps — a basic read/navigate command set plus read-only git
///   (status/log/diff/show/branch/remote).
/// - **full** apps — every command the host offers (`allow: [*]`).
///
/// Network defaults ride the level: L1 has none, L2 allows the common dev
/// hosts on 443, L3 allows everything. A preset is not a file: ids resolve
/// to generated manifests (rooted at the **current folder**) through
/// [CubePresets.manifestYaml], parsed by the strict [CubeSpec] parser — so
/// a preset can never drift from the schema. A project manifest with the
/// same name still wins (resolution order lives in `CubeResolver`).
///
/// Ids are written lowercase (`l2-full`); the bare level (`L2`, `l2`)
/// selects the conservative `core` app axis.
library;

import 'package:yaml/yaml.dart';

import 'cube_spec.dart';

/// One built-in security level preset.
final class CubePreset {
  /// Creates a preset descriptor.
  const CubePreset({
    required this.id,
    required this.level,
    required this.apps,
    required this.title,
    required this.description,
  });

  /// Manifest id: `l<n>-<core|full>` (lowercase).
  final String id;

  /// The protection level label: `L1`, `L2` or `L3`.
  final String level;

  /// The application axis: `core` or `full`.
  final String apps;

  /// Short picker label: `L2 · core apps`.
  final String title;

  /// One-line human description shown in pickers and `/cube list`.
  final String description;
}

/// The built-in preset catalog and its manifest generator.
final class CubePresets {
  CubePresets._();

  /// The protection levels, strongest first.
  static const levels = ['L1', 'L2', 'L3'];

  /// The application axes.
  static const appAxes = ['core', 'full'];

  /// The dev hosts L2's network allows on 443.
  static const l2NetworkHosts = [
    'api.github.com',
    'raw.githubusercontent.com',
    'objects.githubusercontent.com',
    'codeload.github.com',
    'pub.dev',
    'registry.npmjs.org',
    'pypi.org',
    'files.pythonhosted.org',
    'crates.io',
    'static.crates.io',
  ];

  /// The basic read/navigate command set of the `core` app axis (plus
  /// read-only git subcommands).
  static const coreToolAllow = [
    'ls',
    'cat',
    'head',
    'tail',
    'grep',
    'rg',
    'find',
    'fd',
    'pwd',
    'echo',
    'wc',
    'sort',
    'uniq',
    'diff',
    'stat',
    'file',
    'du',
    'tree',
    'which',
    'whoami',
    'date',
    'uname',
    'git status',
    'git log',
    'git diff',
    'git show',
    'git branch',
    'git remote',
  ];

  /// Every preset: 3 levels × 2 app axes.
  static List<CubePreset> get all => [
    for (final level in levels)
      for (final apps in appAxes) _preset(level, apps),
  ];

  /// Looks a preset up by id; accepts the bare level (`L2`, `l2`) as the
  /// conservative `core` axis. Null when [id] is not a preset id.
  static CubePreset? byId(String id) {
    final normalized = id.trim().toLowerCase();
    final match = RegExp(r'^(l[123])(?:-(core|full))?$').firstMatch(normalized);
    if (match == null) return null;
    return _preset(match.group(1)!.toUpperCase(), match.group(2) ?? 'core');
  }

  /// Generates the preset's manifest yaml rooted at [cwd] (the sandbox
  /// workspace). Parsed by the strict [CubeSpec] parser — never hand-fed
  /// into the runtime.
  static String manifestYaml(CubePreset preset, String cwd) {
    final level = preset.level;
    final apps = preset.apps;
    final buffer = StringBuffer()
      ..writeln('apiVersion: fa/v1')
      ..writeln('kind: Cube')
      ..writeln('metadata:')
      ..writeln('  name: ${preset.id}')
      ..writeln("  description: '${_q(preset.description)}'")
      ..writeln('spec:')
      ..writeln('  backend: kernel')
      ..writeln('  tools:');
    if (apps == 'full') {
      buffer.writeln('    allow: ["*"]');
    } else {
      buffer.writeln('    allow:');
      for (final tool in coreToolAllow) {
        buffer.writeln("      - '${_q(tool)}'");
      }
    }
    buffer.writeln('  network:');
    if (level == 'L3') {
      buffer.writeln('    allow:');
      buffer.writeln('      - {host: "*"}');
    } else if (level == 'L2') {
      buffer.writeln('    allow:');
      for (final host in l2NetworkHosts) {
        buffer.writeln('      - {host: $host, ports: [443]}');
      }
    } else {
      buffer.writeln('    allow: []');
    }
    buffer
      ..writeln('  filesystem:')
      ..writeln('    workspace: ${_yq(cwd)}');
    if (level == 'L2') {
      buffer
        ..writeln('    mounts:')
        ..writeln('      - {path: ${_yq(cwd)}, access: rw}')
        ..writeln('      - {path: "/", access: ro}');
    } else if (level == 'L3') {
      buffer
        ..writeln('    mounts:')
        ..writeln('      - {path: "/", access: rw}');
    }
    return buffer.toString();
  }

  /// Resolves a preset id to a parsed [CubeSpec] rooted at [cwd]; null when
  /// [name] is not a preset id (the resolver treats that as a file lookup).
  static CubeSpec? maybeSpec({required String name, required String cwd}) {
    final preset = byId(name);
    if (preset == null) return null;
    return CubeSpec.fromYaml(
      loadYaml(manifestYaml(preset, cwd)),
      sourcePath: 'builtin:${preset.id}',
    );
  }

  static CubePreset _preset(String level, String apps) {
    final appsLabel = apps == 'core' ? 'core apps' : 'full system apps';
    final String body;
    switch (level) {
      case 'L1':
        body = 'reads and writes only the current folder';
      case 'L2':
        body = 'reads everywhere, writes only the current folder';
      default:
        body = 'reads and writes everywhere';
    }
    final network = switch (level) {
      'L1' => 'no network',
      'L2' => 'dev hosts on 443',
      _ => 'full network',
    };
    final tools = apps == 'core' ? 'basic read-only commands' : 'any command';
    return CubePreset(
      id: '${level.toLowerCase()}-$apps',
      level: level,
      apps: apps,
      title: '$level · $appsLabel',
      description: '$level — $body; $tools; $network.',
    );
  }

  /// Single-quotes [value] for yaml (doubles inner single quotes).
  static String _yq(String value) => "'${value.replaceAll("'", "''")}'";

  /// Escapes [value] for embedding inside a single-quoted yaml scalar.
  static String _q(String value) => value.replaceAll("'", "''");
}
