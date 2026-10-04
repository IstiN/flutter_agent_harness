/// Frozen-seed guard for the app's stale-seed cleanup (issue #1151 review
/// CQE1): the app deletes a seeded copy of a retired skill from user
/// machines ONLY when its SKILL.md is byte-identical to the last bytes the
/// old seeder wrote — the `_staleSeedFingerprints` map in
/// `flutter_app/lib/services/agent_service_skills.dart`. The repo's own
/// `.fah/skills/<name>/SKILL.md` copies ARE those bytes (the seeder's
/// historical source), so they are FROZEN: any edit — even a docs
/// improvement — changes the hash, the cleanup stops matching, and
/// `flutter_app/test/skills_toggles_store_test.dart` fails from the app
/// side. This guard fails at CLI-suite level, right where such an edit
/// happens (gh-1198: an Output-section addition to the retired
/// fa-self-config copy drifted it and broke the app gate).
///
/// The expected fingerprints are parsed out of the app source, so this
/// test can never drift from the runtime constant. Documentation changes
/// belong in the live skill (`prompts/skills/<name>/SKILL.md`), never in
/// the frozen seed.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

final _repoRoot = Directory.current.path;
final _appSource = File(
  '$_repoRoot/flutter_app/lib/services/agent_service_skills.dart',
).readAsStringSync();

/// The `const _staleSeedFingerprints = <String, String>{ ... };` literal.
final _fingerprintMap = RegExp(
  r'const _staleSeedFingerprints = <String, String>\{([\s\S]*?)\};',
).firstMatch(_appSource)?.group(1);

final _fingerprintEntries = RegExp(
  r"'([a-z0-9-]+)':\s*'([0-9a-f]{64})',",
).allMatches(_fingerprintMap ?? '');

/// gh-1164 Part A: the js-apps retirement pins EVERY historical
/// per-platform variant of the bundled seed (the old seeder wrote
/// `filterPlatformInstructions(rawAsset, platform: P)`), recomputed from
/// the frozen raw bytes.
final _bundledMap = RegExp(
  r'const _staleBundledSeedFingerprints = <String, Set<String>>\{([\s\S]*?)\};',
).firstMatch(_appSource)?.group(1);

final _bundledEntries = RegExp(
  r"'([a-z0-9-]+)':\s*\{([\s\S]*?)\}",
).allMatches(_bundledMap ?? '');

/// Dart port of `filterPlatformInstructions` (flutter_app apps_store.dart)
/// — the root package cannot import the app, and the guard must recompute
/// the exact bytes the old seeder wrote per platform.
String _filterPlatformInstructions(String source, String platform) {
  final block = RegExp(
    r'<!-- fa-platforms:\s*([^>]+?)\s*-->(.*?)<!-- /fa-platforms -->',
    dotAll: true,
  );
  var filtered = source.replaceAllMapped(block, (match) {
    return _platformList(match.group(1)).contains(platform)
        ? match.group(2)!
        : '';
  });
  final taggedLine = RegExp(
    r'^.*<!-- fa-platforms:\s*([^>]+?)\s*-->.*$',
    multiLine: true,
  );
  filtered = filtered.replaceAllMapped(taggedLine, (match) {
    if (!_platformList(match.group(1)).contains(platform)) return '';
    return match
        .group(0)!
        .replaceFirst(RegExp(r'\s*<!-- fa-platforms:\s*[^>]+?\s*-->'), '');
  });
  return filtered.replaceAll('{{FA_PLATFORM}}', platform);
}

Set<String> _platformList(Object? value) => {
  for (final item in switch (value) {
    List<Object?> values => values,
    String text => text.split(','),
    _ => const <Object?>[],
  })
    if (item.toString().trim().isNotEmpty) item.toString().trim().toLowerCase(),
};

void main() {
  test(
    'every retired-seed fingerprint matches the repo copy byte-for-byte',
    () {
      expect(
        _fingerprintMap,
        isNotNull,
        reason:
            'the _staleSeedFingerprints literal moved in the app source — '
            'update this parser',
      );
      expect(
        _fingerprintEntries,
        isNotEmpty,
        reason: 'no fingerprints parsed from _staleSeedFingerprints',
      );

      for (final match in _fingerprintEntries) {
        final name = match.group(1)!;
        final fingerprint = match.group(2)!;
        final file = File('$_repoRoot/.fah/skills/$name/SKILL.md');
        expect(
          file.existsSync(),
          isTrue,
          reason:
              '$name has a stale-seed fingerprint in the app but no repo '
              'copy at .fah/skills/$name/SKILL.md',
        );
        final actual = sha256
            .convert(utf8.encode(file.readAsStringSync()))
            .toString();
        expect(
          actual,
          fingerprint,
          reason:
              '.fah/skills/$name/SKILL.md drifted from the last-seeded bytes '
              'pinned in the app\'s _staleSeedFingerprints — the app can no '
              'longer recognize (and clean up) stale seeds on user machines. '
              'The retired seed is FROZEN; document changes go to the live '
              'skill (prompts/skills/<live-name>/SKILL.md) instead.',
        );
      }
    },
  );

  test(
    'every retired-BUNDLED-seed fingerprint matches a per-platform variant '
    'of the frozen raw bytes (gh-1164 js-apps)',
    () {
      expect(
        _bundledMap,
        isNotNull,
        reason:
            'the _staleBundledSeedFingerprints literal moved in the app '
            'source — update this parser',
      );
      expect(
        _bundledEntries,
        isNotEmpty,
        reason: 'no bundled fingerprints parsed from the app source',
      );
      const platforms = ['macos', 'ios', 'android', 'windows', 'linux', 'web'];
      for (final match in _bundledEntries) {
        final name = match.group(1)!;
        final hashes = RegExp(r"'([0-9a-f]{64})'")
            .allMatches(match.group(2)!)
            .map((m) => m.group(1)!)
            .toSet();
        final fixture = File(
          '$_repoRoot/flutter_app/test/fixtures/retired_${name.replaceAll('-', '_')}_skill.md',
        );
        expect(
          fixture.existsSync(),
          isTrue,
          reason: 'frozen raw bytes of the retired bundled skill missing',
        );
        final raw = fixture.readAsStringSync();
        final expected = {
          for (final platform in platforms)
            sha256
                .convert(utf8.encode(_filterPlatformInstructions(raw, platform)))
                .toString(),
        };
        expect(
          hashes,
          expected,
          reason:
              'the _staleBundledSeedFingerprints[$name] map must pin exactly '
              'per-platform variants of the frozen raw bytes — the old '
              'seeder wrote filterPlatformInstructions(raw, platform: P) '
              'per platform, so the cleanup accepts any of them.',
        );
      }
    },
  );
}
