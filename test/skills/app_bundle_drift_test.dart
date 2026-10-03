/// S5 drift guard (issue #29, reworked by #1151): every first-party skill
/// under `.fah/skills/` reaches app sessions EITHER as a package built-in
/// (embedded by `scripts/gen_prompts.dart` into `builtinSkillFiles`) OR —
/// for app-only skills with no package embedding — as a bundled asset
/// (`flutter_app/assets/skills/`, listed in the app's pubspec and seeded
/// into sessions by `AgentService._seedBundledSkills`). Skills that are
/// both bundled and embedded are forbidden: the seeded project copy would
/// shadow the built-in with a duplicate listing.
///
/// VM-only (reads files from disk).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Platform-filter mirror (flutter_app/lib/apps/apps_store.dart): the
/// pre-gh-1164 app seeder wrote the js-apps asset through it, so the
/// retirement fingerprints pin the FILTERED bytes per platform.
String _filterPlatformInstructions(String source, {required String platform}) {
  final block = RegExp(
    r'<!-- fa-platforms:\s*([^>]+?)\s*-->(.*?)<!-- /fa-platforms -->',
    dotAll: true,
  );
  var filtered = source.replaceAllMapped(block, (match) {
    final platforms = (match.group(1) ?? '')
        .split(',')
        .map((p) => p.trim().toLowerCase())
        .toSet();
    return platforms.contains(platform) ? (match.group(2) ?? '') : '';
  });
  final taggedLine = RegExp(
    r'^.*<!-- fa-platforms:\s*([^>]+?)\s*-->.*$',
    multiLine: true,
  );
  filtered = filtered.replaceAllMapped(taggedLine, (match) {
    final platforms = (match.group(1) ?? '')
        .split(',')
        .map((p) => p.trim().toLowerCase())
        .toSet();
    if (!platforms.contains(platform)) return '';
    return (match.group(0) ?? '').replaceFirst(
      RegExp(r'\s*<!-- fa-platforms:\s*[^>]+?\s*-->'),
      '',
    );
  });
  return filtered.replaceAll('{{FA_PLATFORM}}', platform);
}

void main() {
  final skills = Directory('.fah/skills');
  // gh-1164 retired the js-apps asset (promoted to a package builtin);
  // the directory may be absent entirely — the guards below then verify
  // the empty-bundle state instead of throwing on a missing dir.
  final bundled = Directory('flutter_app/assets/skills');
  final bundledDirs = bundled.existsSync()
      ? bundled.listSync().whereType<Directory>().toList()
      : const <Directory>[];
  final embedded = builtinSkills().map((s) => s.name).toSet();

  test('every first-party skill ships as a builtin or a bundled app asset', () {
    expect(skills.existsSync(), isTrue, reason: '.fah/skills missing');
    final names =
        skills
            .listSync()
            .whereType<Directory>()
            .map((d) => d.uri.pathSegments.reversed.toList()[1])
            .toList()
          ..sort();
    expect(names, isNotEmpty);

    final pubspec = File('flutter_app/pubspec.yaml').readAsStringSync();
    for (final name in names) {
      final asset = File('flutter_app/assets/skills/$name/SKILL.md');
      if (embedded.contains(name)) {
        // #1151: shipped inside the core package - invocable on every
        // surface. The .fah/skills copy stays as a project override
        // (non-goal to migrate), but a bundled app copy would shadow the
        // builtin with a duplicate listing.
        expect(
          asset.existsSync(),
          isFalse,
          reason:
              'skill "$name" is embedded as a package builtin; the '
              'bundled app copy shadows it with a duplicate listing - '
              'delete flutter_app/assets/skills/$name/',
        );
        expect(
          pubspec.contains('assets/skills/$name/'),
          isFalse,
          reason:
              'skill "$name" is embedded as a package builtin but still '
              'listed in flutter_app/pubspec.yaml assets',
        );
        continue;
      }
      // Not embedded: project override. If the app bundles it anyway,
      // the old mirror rules apply; otherwise project-only is fine.
      if (!asset.existsSync()) continue;
      expect(
        pubspec,
        contains('assets/skills/$name/SKILL.md'),
        reason:
            'skill "$name" is bundled but not listed in '
            'flutter_app/pubspec.yaml assets',
      );
    }
  });

  test('bundled SKILL.md copies are byte-identical to the source skill', () {
    for (final dir in bundledDirs) {
      final name = dir.uri.pathSegments.reversed.toList()[1];
      final source = File('.fah/skills/$name/SKILL.md');
      final copy = File('flutter_app/assets/skills/$name/SKILL.md');
      if (!source.existsSync()) continue; // app-only skill, no source pin
      expect(
        copy.readAsStringSync(),
        source.readAsStringSync(),
        reason:
            'flutter_app/assets/skills/$name/SKILL.md drifted from '
            '.fah/skills/$name/SKILL.md - re-copy the source skill '
            '(the source of truth is .fah/skills/)',
      );
    }
  });

  test('gh-1164: the js-apps retirement fingerprints match the retired '
      'asset at git HEAD', () {
    // The app's stale-seed cleanup pins the pre-promotion seeded bytes
    // (one sha256 per host platform, computed with the platform filter).
    // A typo'd hash would leave the old seeded copy shadowing the builtin
    // forever — recompute the set from the retired asset and compare.
    final asset = Process.runSync('git', [
      'show',
      'HEAD:flutter_app/assets/skills/js-apps/SKILL.md',
    ]);
    expect(
      asset.exitCode,
      0,
      reason:
          'the retired asset must stay in git '
          'history — the retirement fingerprints verify against it',
    );
    final seeder = File(
      'flutter_app/lib/services/agent_service_skills.dart',
    ).readAsStringSync();
    final expected = <String>{};
    for (final platform in [
      'web',
      'android',
      'ios',
      'macos',
      'windows',
      'linux',
      'fuchsia',
    ]) {
      final filtered = _filterPlatformInstructions(
        asset.stdout as String,
        platform: platform,
      );
      final hash = sha256.convert(utf8.encode(filtered)).toString();
      expected.add(hash);
      expect(
        seeder,
        contains("'$hash'"),
        reason: 'missing retirement fingerprint for platform $platform',
      );
    }
    final hashPattern = RegExp(r"'([0-9a-f]{64})'");
    final declared = hashPattern
        .allMatches(seeder.substring(seeder.indexOf("'js-apps': {")))
        .map((m) => m.group(1)!)
        .toSet();
    expect(
      declared,
      expected,
      reason:
          'the js-apps fingerprint set must '
          'carry EXACTLY the per-platform filtered asset hashes',
    );
  });

  test('AgentService._seedBundledSkills registers every bundled skill', () {
    // The audit (issue #29 AC10): the drift guard must pin the SEEDER,
    // not just the files — a skill added to assets + pubspec but not to
    // the seeder map would never reach a session. The map lives in the
    // app source (the skills part file since #1151's size gate); parse
    // it (a string-literal map, VM-only guard).
    final source = File(
      'flutter_app/lib/services/agent_service_skills.dart',
    ).readAsStringSync();
    final decl = source.indexOf('Future<void> _seedBundledSkills');
    expect(decl, greaterThanOrEqualTo(0), reason: 'seeder missing');
    final brace = source.indexOf('= {', decl);
    final mapEnd = source.indexOf('};', brace);
    expect(brace, greaterThan(decl), reason: 'seeder map open missing');
    expect(mapEnd, greaterThan(brace), reason: 'seeder map close missing');
    final seeded = RegExp(r"'([a-zA-Z0-9-]+)':")
        .allMatches(source.substring(brace, mapEnd))
        .map((m) => m.group(1)!)
        .toSet();
    final bundledNames = bundledDirs
        .map((d) => d.uri.pathSegments.reversed.toList()[1])
        .toSet();
    expect(
      seeded,
      containsAll(bundledNames),
      reason:
          'bundled skill(s) not registered in AgentService._seedBundledSkills '
          '- a session would never see them',
    );
  });
}
