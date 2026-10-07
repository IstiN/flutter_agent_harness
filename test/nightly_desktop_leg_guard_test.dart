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
//       flutter_app resolution enforces it — packaging scripts resolve
//       with --enforce-lockfile, and the workflow steps ride the shared
//       composite action (.github/actions/flutter-pub-get), pinned by
//       test/ci_pub_get_retry_guard_test.dart — so transitive drift
//       surfaces as a PR diff,
//  AC3  the parent dep + versions that introduced the drift, in code:
//       flutter_inappwebview 6.2.0-beta.3 (direct, gh-1235) →
//       flutter_inappwebview_linux 0.1.0-beta.1 /
//       flutter_inappwebview_windows 0.7.0-beta.3 (native desktop legs).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

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
    // Directory-only and ** subtleties don't occur for this path. A pattern
    // containing a slash (with or without a leading one) is anchored to the
    // .gitignore's directory; a bare name matches any path segment.
    final anchored = line.startsWith('/') || line.contains('/');
    final pattern = line.startsWith('/') ? line.substring(1) : line;
    final matches = anchored
        ? path == pattern || path.startsWith('$pattern/')
        : path.split('/').contains(pattern);
    if (matches) ignored = !negate;
  }
  return ignored;
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

    test('lockfile is in sync with the current package versions', () {
      // The lockfile records the resolved version of the root
      // flutter_agent_harness path dependency. A merge from main that
      // bumps the root/app version (chore(release) commits) without
      // regenerating flutter_app/pubspec.lock makes every
      // `flutter pub get --enforce-lockfile` step in CI exit 1 ("Unable
      // to satisfy pubspec.yaml using pubspec.lock") — the exact
      // Quality-gate red this PR landed with on head a702c3170.
      final rootVersion =
          (loadYaml(read('pubspec.yaml')) as YamlMap)['version'] as String;
      final rootName = (loadYaml(read('pubspec.yaml')) as YamlMap)['name']
          as String;
      final appVersion =
          (loadYaml(read('flutter_app/pubspec.yaml')) as YamlMap)['version']
              as String?;
      final lock = loadYaml(read('flutter_app/pubspec.lock')) as YamlMap;
      final lockedRoot =
          (lock['packages'] as YamlMap)[rootName] as YamlMap?;
      expect(
        lockedRoot,
        isNotNull,
        reason: 'flutter_app/pubspec.lock must record the $rootName path '
            'dependency.',
      );
      // The root pubspec carries the bare version (e.g. 1.0.513); the app
      // pubspec may carry build metadata (e.g. 1.0.513+1). The lockfile
      // records the bare version for path deps.
      expect(
        lockedRoot!['version'],
        rootVersion.split('+').first,
        reason: 'the committed lockfile was generated against an older '
            '$rootName version — regenerate it with `cd flutter_app && '
            'flutter pub get` after any version bump, or CI\'s '
            '--enforce-lockfile steps fail (gh-1265 AC2 REG guard).',
      );
      // Sanity: the app version must not lag the root version either —
      // both are bumped together by the release chore.
      expect(
        appVersion?.split('+').first,
        rootVersion.split('+').first,
        reason: 'flutter_app/pubspec.yaml version must match the root '
            'pubspec.yaml version (release chore bumps both).',
      );
    });

    test('packaging scripts resolve flutter_app with --enforce-lockfile', () {
      // AC2 drift hole (PR #1268 review thread 1): the workflow YAML steps
      // are all converted, but the packaging scripts they invoke resolve
      // flutter_app deps themselves — this guard only parses workflow `run`
      // steps, so a plain `flutter pub get` inside a script floats silently
      // (worst case: build-macos.yml's release job, where the script's
      // resolve is the ONLY flutter_app resolution → green release build
      // with floated deps).
      for (final script in [
        'scripts/build_browser_ext.sh',
        'scripts/build_office_addin.sh',
      ]) {
        final body = read(script);
        final invocations = RegExp(r'flutter pub get[^&|\n\\]*')
            .allMatches(body)
            .map((m) => m.group(0)!)
            .toList();
        expect(
          invocations,
          isNotEmpty,
          reason: '$script must resolve flutter_app dependencies via '
              '`flutter pub get` before building the web app.',
        );
        for (final invocation in invocations) {
          expect(
            invocation,
            contains('--enforce-lockfile'),
            reason: '$script resolves flutter_app deps outside the '
                'workflow guard — on a pubspec/lockfile skew it would '
                'silently regenerate the lockfile instead of failing '
                '(gh-1265 AC2).',
          );
        }
      }
    });

    test('root .gitignore has no duplicated rule blocks', () {
      // PR #1268 review thread 2: the root .gitignore carried its first
      // block twice; the `!flutter_app/pubspec.lock` negation only worked
      // by accident of that duplication (last match wins). After the
      // dedupe it must be the single copy, with the negation after the
      // one remaining `pubspec.lock` rule.
      final lines = read('.gitignore')
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();
      final seen = <String>{};
      final duplicates = <String>[];
      for (final line in lines) {
        if (!seen.add(line)) duplicates.add(line);
      }
      expect(
        duplicates,
        isEmpty,
        reason: 'root .gitignore contains duplicated rules: $duplicates — '
            'collapse the doubled block (pure deletion) so the '
            '!flutter_app/pubspec.lock negation cannot be silently '
            're-broken by a future dedupe.',
      );
      // The negation must follow EVERY bare `pubspec.lock` ignore rule.
      final raw = read('.gitignore').split('\n');
      final negationIndex = raw.lastIndexWhere(
        (l) => l.trim() == '!flutter_app/pubspec.lock',
      );
      expect(negationIndex, greaterThanOrEqualTo(0));
      for (var i = 0; i < raw.length; i++) {
        final line = raw[i].trim();
        if (line == 'pubspec.lock' ||
            (line.startsWith('/') && line.substring(1) == 'pubspec.lock')) {
          expect(
            i,
            lessThan(negationIndex),
            reason: 'a `pubspec.lock` ignore rule at line ${i + 1} sits '
                'AFTER the !flutter_app/pubspec.lock negation — last '
                'match wins, so the app lockfile would be ignored again.',
          );
        }
      }
    });

    test('the shared pub-get action fails fast on deterministic skew', () {
      // PR #1268 review thread 3: the bounded retry loop exists for
      // transient runner/network failures — but a pubspec/lockfile skew
      // fails identically on every attempt, costing ~30s per red leg and
      // blaming the network. The loop must detect the skew signature in
      // the failed resolve's output and exit immediately. gh-1310 moved
      // the loop OUT of build-mobile.yml into the shared composite action
      // every enforce-lockfile pub get rides
      // (.github/actions/flutter-pub-get) — the guard follows it there.
      final body = read('.github/actions/flutter-pub-get/action.yml');
      expect(body, contains('for attempt in 1 2 3'));
      expect(body, contains('flutter pub get --enforce-lockfile'));
      expect(
        body,
        contains(RegExp(r'Unable to satisfy .+pubspec')),
        reason: 'the retry loop must match the deterministic '
            'lockfile-skew signature ("Unable to satisfy ... using ... '
            'pubspec.lock") in the failed output and fail fast instead '
            'of retrying (gh-1265 AC2).',
      );
    });

    // The per-workflow "resolves flutter_app with --enforce-lockfile"
    // loop (gh-1265) is retired: gh-1310 moved every flutter_app pub-get
    // run-step out of the workflows into the shared composite action, so
    // the loop iterated an empty set — vacuous, and blind to the
    // `working-directory: ./flutter_app` spelling. The resolution
    // invariants now live in test/ci_pub_get_retry_guard_test.dart
    // (AC2: no bare run-step; AC3: per-workflow action-step counts).
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
      // js_widget_runtime, hosted 0.4.156, declares no
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
