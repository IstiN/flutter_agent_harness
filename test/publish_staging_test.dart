// Issue #584: the tag-release publish leg builds a staged copy of the repo
// (scripts/stage_publish_package.sh, called from the "Stage publishable
// package" step) and runs `dart pub get` inside it. If any `path:`
// dependency of the core pubspec is stripped by the staging rsync filters,
// resolution dies with exit 66 AFTER a tag is cut — v0.1.406 and v0.1.407
// both blocked releases this way.
//
// These tests parse the staging script's rsync include/exclude list (single
// source of truth — no copy of the filter list lives here) and simulate
// rsync's first-match-wins filtering to prove the staged tree stays
// self-consistent: every path dependency of pubspec.yaml lands in the stage,
// and pubspec_overrides.yaml (workspace-only dart_tui pin, never published)
// does not leak into it.
//
// ponytail: static filter simulation, not a real rsync run — CI has no
// guarantee of rsync here; upgrade to executing the stage if filters grow
// semantics this simulator can't express (patterns beyond *, **, ?, trailing /).
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _stagingScript = 'scripts/stage_publish_package.sh';
const _stageMarker = 'rsync -a';
const _overridesFile = 'pubspec_overrides.yaml';

class _Filter {
  _Filter(this.include, this.pattern)
      : dirOnly = pattern.endsWith('/'),
        anchored = pattern.contains('/') {
    final unanchored =
        pattern.endsWith('/') ? pattern.substring(0, pattern.length - 1) : pattern;
    // rsync anchors a leading `/` on the transfer root — the body itself
    // carries no slash (issue #613).
    body = unanchored.startsWith('/') ? unanchored.substring(1) : unanchored;
  }

  final bool include;
  final String pattern;
  final bool dirOnly;
  final bool anchored;
  late final String body;
}

/// Ordered include/exclude list of the staging rsync command in the script.
List<_Filter> _stagingFilters() {
  final lines = File(_stagingScript).readAsLinesSync();
  final start = lines.indexWhere((l) => l.contains(_stageMarker));
  if (start < 0) {
    fail('staging rsync command not found in $_stagingScript — update this test');
  }
  final filters = <_Filter>[];
  // The command continues across lines ending with a backslash.
  var block = [lines[start]];
  for (var i = start + 1; i < lines.length; i++) {
    block.add(lines[i]);
    // The last line of the command carries no trailing backslash —
    // stopping BEFORE adding it silently dropped its filters (issue #613).
    if (!lines[i].trimRight().endsWith(r'\')) break;
  }
  final argPattern = RegExp(r"--(include|exclude) '([^']+)'");
  for (final line in block) {
    for (final m in argPattern.allMatches(line)) {
      filters.add(_Filter(m.group(1) == 'include', m.group(2)!));
    }
  }
  return filters;
}

bool _globMatch(String glob, String s) {
  final sb = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    if (c == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        sb.write('.*');
        i++;
      } else {
        sb.write('[^/]*');
      }
    } else if (c == '?') {
      sb.write('[^/]');
    } else {
      sb.write(RegExp.escape(c));
    }
  }
  sb.write(r'$');
  return RegExp(sb.toString()).hasMatch(s);
}

bool _matches(_Filter f, String path, bool isDir) {
  if (f.dirOnly && !isDir) return false;
  if (f.anchored) return _globMatch(f.body, path);
  // Unanchored patterns match against any single path component.
  return path.split('/').any((c) => _globMatch(f.body, c));
}

/// rsync first-match-wins for one path: true = transferred, false = excluded.
bool _firstMatchKeeps(List<_Filter> filters, String path, bool isDir) {
  for (final f in filters) {
    if (_matches(f, path, isDir)) return f.include;
  }
  return true; // no rule matched -> transferred
}

/// Would rsync transfer [file]? Every ancestor dir must stay descendable
/// (an excluded parent prunes the whole subtree regardless of child rules).
bool _landsInStage(List<_Filter> filters, String file) {
  final parts = file.split('/');
  for (var i = 1; i < parts.length; i++) {
    if (!_firstMatchKeeps(filters, parts.sublist(0, i).join('/'), true)) {
      return false;
    }
  }
  return _firstMatchKeeps(filters, file, false);
}

/// name -> path target for every path dependency of pubspec.yaml.
Map<String, String> _pubspecPathDeps() {
  final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
  final deps = <String, String>{};
  for (final section in ['dependencies', 'dev_dependencies', 'dependency_overrides']) {
    final m = pubspec[section];
    if (m is! YamlMap) continue;
    m.forEach((name, spec) {
      if (spec is YamlMap && spec['path'] is String) {
        deps[name as String] = spec['path'] as String;
      }
    });
  }
  return deps;
}

void main() {
  group('publish staging self-consistency (issue #584)', () {
    test('staging rsync block carries filter rules', () {
      expect(_stagingFilters(), isNotEmpty,
          reason: 'no --include/--exclude rules parsed from $_stagingScript');
    });

    test('every pubspec path dependency lands in the staged tree', () {
      final filters = _stagingFilters();
      final deps = _pubspecPathDeps();
      expect(deps, isNotEmpty, reason: 'fixture sanity: pubspec.yaml has path deps');
      for (final entry in deps.entries) {
        final probe = '${entry.value}/pubspec.yaml';
        expect(File(probe).existsSync(), isTrue,
            reason: '$probe missing from the working tree itself');
        expect(_landsInStage(filters, probe), isTrue,
            reason: 'staging strips ${entry.value} but pubspec.yaml keeps '
                '${entry.key} on it — `dart pub get` in the publish stage dies '
                'with exit 66 (v0.1.407, issue #584)');
      }
    });

    test('pubspec_overrides.yaml never leaks into the staged tree', () {
      // Workspace-only dart_tui pin (path: vendor/dart_tui); shipped into the
      // stage it re-dangles dart_tui onto the excluded vendor dir — the exact
      // v0.1.407 failure. The published package resolves hosted dart_tui.
      expect(_landsInStage(_stagingFilters(), _overridesFile), isFalse,
          reason: '$_overridesFile must be excluded from the publish stage');
    });

    test('root-scoped excludes prune only the repo root (issue #613)', () {
      // v0.1.411: unanchored `--exclude 'memory'` matched ANY directory
      // named `memory`, pruning lib/src/memory/ out of the stage — the
      // published package shipped broken memory imports. Root-scoped
      // excludes must be anchored; package subtrees must survive.
      final filters = _stagingFilters();
      expect(_landsInStage(filters, 'lib/src/memory/memory_controller.dart'), isTrue,
          reason: 'lib/src/memory/ is package surface — pruning it ships '
              'uri_does_not_exist (v0.1.411, issue #613)');
      expect(_landsInStage(filters, 'memory/note/n_0001_abcd.md'), isFalse,
          reason: 'the repo-root memory/ dir stays out of the stage');
      expect(_landsInStage(filters, 'docs/architecture.md'), isFalse,
          reason: 'the repo-root docs/ dir stays out of the stage');
    });
  });
}
