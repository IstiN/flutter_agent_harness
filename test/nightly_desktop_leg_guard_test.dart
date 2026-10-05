// gh-1265 — the nightly desktop release legs (linux + windows) went red for
// 5 nights because gh-1235's direct `flutter_inappwebview: ^6.2.0-beta.3`
// dep drags the plugin's UNUSED desktop implementations into every native
// desktop build: linux hard-requires the WPE WebKit system library (absent
// from Ubuntu 24.04 — libwpewebkit-1.0-dev is jammy-only), and windows C++17
// sources without /await trip MSVC 14.51's STL1011 on
// <experimental/coroutine>. The app never uses the plugin on Linux/Windows
// (createFaWebViewHost() returns null there — placeholder fallback).
//
// Deliberately text/YAML-level asserts (the issue's "static assert in CI"
// pattern, same as store_automation_guard_test.dart): they pin
//  AC1  the desktop plugin impls carry no native plugin registration
//       (stub overrides under vendor/) so the linux/windows release legs
//       build the same native surface they had when last green,
//  AC2  flutter_app/pubspec.lock is committed (not gitignored) and every
//       workflow's flutter_app pub-get step resolves with
//       --enforce-lockfile, so transitive drift surfaces as a PR diff,
//  AC3  the parent dep + versions that introduced the drift, in code:
//       flutter_inappwebview 6.2.0-beta.3 (direct, gh-1235) →
//       flutter_inappwebview_linux 0.1.0-beta.1 /
//       flutter_inappwebview_windows 0.7.0-beta.3 (native desktop legs).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

/// Workflow files whose flutter_app `flutter pub get` steps must resolve
/// against the committed lockfile. (Root-level `dart pub get` steps use the
/// root library lockfile, which has always been committed; `packages/fa_ui`
/// and friends are libraries whose lockfiles stay uncommitted.)
const enforcedWorkflows = [
  '.github/workflows/ci.yml',
  '.github/workflows/nightly.yml',
  '.github/workflows/build-mobile.yml',
  '.github/workflows/build-macos.yml',
  '.github/workflows/browser-ext.yml',
  '.github/workflows/office-addin.yml',
];

/// Minimal gitignore rule evaluation for the single path we care about:
/// returns true if [path] (repo-relative) ends up IGNORED. Handles the only
/// constructs the repo's root .gitignore uses for lockfiles: bare names
/// (match any path segment) and leading-slash anchored names, with `!`
/// negations applied in file order.
bool gitIgnored(String path, String gitignore) {
  var ignored = false;
  for (final rawLine in gitignore.split('\n')) {
    var line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    var negate = false;
    if (line.startsWith('!')) {
      negate = true;
      line = line.substring(1);
    }
    // Directory-only and ** subtleties don't occur for this path; bare and
    // anchored-name rules cover the repo's lockfile entries.
    final anchored = line.startsWith('/');
    final pattern = anchored ? line.substring(1) : line;
    final matches = anchored
        ? path == pattern || path.startsWith('$pattern/')
        : path.split('/').contains(pattern);
    if (matches) ignored = !negate;
  }
  return ignored;
}

/// Every step of every job in [workflowPath] as (run, workingDirectory).
Iterable<(String, String?)> stepsOf(String workflowPath) sync* {
  final jobs = (loadYaml(read(workflowPath)) as YamlMap)['jobs'] as YamlMap;
  for (final job in jobs.values) {
    final steps = (job as YamlMap)['steps'];
    if (steps is! YamlList) continue;
    for (final step in steps) {
      if (step is YamlMap && step['run'] is String) {
        yield (step['run'] as String, step['working-directory'] as String?);
      }
    }
  }
}

void main() {
  group('AC2 — flutter_app/pubspec.lock is committed and enforced', () {
    test('lockfile exists on disk', () {
      expect(
        File('flutter_app/pubspec.lock').existsSync(),
        isTrue,
        reason: 'flutter_app is an app (publish_to: none) — its lockfile '
            'belongs in git so CI resolves reproducibly (gh-1265).',
      );
    });

    test('lockfile is not gitignored (library lockfiles still are)', () {
      final root = read('.gitignore');
      expect(
        gitIgnored('flutter_app/pubspec.lock', root),
        isFalse,
        reason: 'flutter_app/pubspec.lock must be re-included via a ! '
            'negation in the root .gitignore.',
      );
      expect(
        gitIgnored('pubspec.lock', root),
        isTrue,
        reason: 'the root library lockfile stays uncommitted.',
      );
      expect(
        gitIgnored('packages/fa_ui/pubspec.lock', root),
        isTrue,
        reason: 'library packages under packages/ keep ignoring their '
            'lockfiles.',
      );
    });

    for (final workflow in enforcedWorkflows) {
      test('$workflow resolves flutter_app with --enforce-lockfile', () {
        final offending = stepsOf(workflow)
            .where(
              (step) =>
                  step.$1.contains('flutter pub get') &&
                  (step.$1.contains('flutter_app') ||
                      (step.$2 ?? '').startsWith('flutter_app')),
            )
            .where((step) => !step.$1.contains('--enforce-lockfile'))
            .toList();
        expect(
          offending,
          isEmpty,
          reason: '$workflow has a flutter_app `flutter pub get` without '
              '--enforce-lockfile — a pubspec/lockfile skew would float '
              'silently instead of failing CI (gh-1265 AC2).',
        );
      });
    }
  });

  group('AC1 — desktop plugin impls carry no native registration', () {
    /// The app's webView host is iOS/Android/macOS-only; the federated
    /// desktop implementations are pulled in by the umbrella plugin but
    /// never used (fa_webview_host.dart returns null on Linux/Windows).
    /// They are overridden to stub packages that declare NO flutter plugin
    /// section, so `flutter build linux/windows` compiles no plugin C++.
    const stubs = {
      'flutter_inappwebview_linux': '0.1.0-beta.1',
      'flutter_inappwebview_windows': '0.7.0-beta.3',
    };

    final overrides = ((loadYaml(read('flutter_app/pubspec.yaml')) as YamlMap)[
            'dependency_overrides'] as YamlMap?) ??
        const {};

    for (final entry in stubs.entries) {
      test('${entry.key} is overridden to a stub with no plugin section', () {
        final override = overrides[entry.key];
        expect(
          override,
          isA<YamlMap>(),
          reason: '${entry.key} must be a dependency_override in '
              'flutter_app/pubspec.yaml (gh-1265).',
        );
        final path = (override as YamlMap)['path'] as String?;
        expect(path, isNotNull, reason: 'stub override must be a path dep');
        final stubPubspec = File('flutter_app/${path!}/pubspec.yaml');
        expect(stubPubspec.existsSync(), isTrue, reason: 'stub must exist');
        final stub = loadYaml(stubPubspec.readAsStringSync()) as YamlMap;
        expect(stub['name'], entry.key);
        expect(
          stub['version'],
          entry.value,
          reason: 'stub version should mirror the impl it replaces so the '
              'umbrella constraint stays satisfied.',
        );
        expect(
          stub['publish_to'],
          'none',
          reason: 'stubs are repo-internal, never published.',
        );
        final flutterSection = stub['flutter'];
        expect(
          flutterSection is! YamlMap || !(flutterSection).containsKey('plugin'),
          isTrue,
          reason: 'a stub with a flutter: plugin: section would register '
              'native code on that desktop platform again — exactly what '
              'gh-1265 removes.',
        );
      });
    }
  });

  group('AC3 — the drift parent is pinned and named', () {
    final lock = loadYaml(read('flutter_app/pubspec.lock')) as YamlMap;
    String? lockedVersion(String name) =>
        (lock['packages'] as YamlMap)[name] is YamlMap
            ? ((lock['packages'] as YamlMap)[name] as YamlMap)['version']
                as String?
            : null;

    test('the committed lockfile pins the drift chain', () {
      // Parent dep: the umbrella gh-1235 added directly (data, not vibes —
      // js_widget_runtime, hosted 0.4.155 AND git bd1e7c2, declares no
      // inappwebview dependency; the umbrella is the only graph edge).
      expect(lockedVersion('flutter_inappwebview'), '6.2.0-beta.3');
      // Its desktop impls, kept at the exact versions that broke nightly:
      // linux 0.1.0-beta.1 introduced the WPE system-lib requirement,
      // windows 0.7.0-beta.3 ships the C++17-without-/await sources.
      expect(lockedVersion('flutter_inappwebview_linux'), '0.1.0-beta.1');
      expect(lockedVersion('flutter_inappwebview_windows'), '0.7.0-beta.3');
    });

    test('nightly build-release still exercises linux + windows', () {
      final jobs =
          (loadYaml(read('.github/workflows/nightly.yml')) as YamlMap)['jobs']
              as YamlMap;
      final build = (jobs['build-release'] as YamlMap)['strategy']
          as YamlMap;
      final matrix = build['matrix'] as YamlMap;
      final include = (matrix['include'] ?? matrix['target']) as YamlList;
      final targets = [
        for (final m in include) (m as YamlMap)['target'] as String,
      ];
      expect(targets, containsAll(['linux', 'windows']));
    });
  });
}
