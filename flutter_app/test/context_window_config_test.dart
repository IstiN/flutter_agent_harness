// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2479 — the app's context-window config service:
/// - the cap resolution matrix (no config → uncapped; user cap → user;
///   project overrides user) — the same chain `resolveContextWindowCap`
///   resolves for the CLI;
/// - the cap write/clear: surgical, validated, unrelated bytes survive;
/// - the per-model override write/clear: USER scope, `ModelsConfig`
///   -validated, below-floor values refused with nothing written;
/// - the web stub semantics.
library;

import 'dart:io';

import 'package:fa/services/context_window_config.dart';
// The stub is plain Dart (no dart:io) — imported directly to pin the web
// semantics regardless of the platform the test runs on.
import 'package:fa/services/context_window_config_stub.dart' as web_stub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory tmp;
  late String projectDir;
  late String homeDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fa_ctx2479_');
    projectDir = '${tmp.path}/proj';
    homeDir = '${tmp.path}/home';
    Directory('$projectDir/.fah').createSync(recursive: true);
    Directory('$homeDir/.fah').createSync(recursive: true);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  void writeProject(String yaml) =>
      File('$projectDir/.fah/config.yaml').writeAsStringSync(yaml);

  void writeUser(String yaml) =>
      File('$homeDir/.fah/config.yaml').writeAsStringSync(yaml);

  group('cap resolution matrix', () {
    test('no config anywhere → uncapped (source none)', () {
      final r = resolveAppContextWindowCap(
        projectDir: projectDir,
        homeDir: homeDir,
      );
      expect(r.cap, isNull);
      expect(r.source, AppContextCapSource.none);
    });

    test('user cap → user layer', () {
      writeUser('agent:\n  contextWindowCap: 65536\n');
      final r = resolveAppContextWindowCap(
        projectDir: projectDir,
        homeDir: homeDir,
      );
      expect(r.cap, 65536);
      expect(r.source, AppContextCapSource.user);
    });

    test('project cap wins over the user cap', () {
      writeUser('agent:\n  contextWindowCap: 65536\n');
      writeProject('agent:\n  contextWindowCap: 32768\n');
      final r = resolveAppContextWindowCap(
        projectDir: projectDir,
        homeDir: homeDir,
      );
      expect(r.cap, 32768);
      expect(r.source, AppContextCapSource.project);
    });

    test('a read never creates or mutates config files', () {
      writeUser('# treasured comment\nprovider: openai\n');
      resolveAppContextWindowCap(projectDir: projectDir, homeDir: homeDir);
      expect(
        File('$homeDir/.fah/config.yaml').readAsStringSync(),
        '# treasured comment\nprovider: openai\n',
      );
    });
  });

  group('cap write/clear', () {
    test('user-scope set lands in the user file and re-resolves', () async {
      final file = await writeAppContextWindowCap(
        200000,
        layer: AppContextCapSource.user,
        projectDir: projectDir,
        homeDir: homeDir,
      );
      expect(file, '$homeDir/.fah/config.yaml');
      final r = resolveAppContextWindowCap(
        projectDir: projectDir,
        homeDir: homeDir,
      );
      expect(r.cap, 200000);
      expect(r.source, AppContextCapSource.user);
    });

    test('project-scope set lands in the project file', () async {
      final file = await writeAppContextWindowCap(
        32768,
        layer: AppContextCapSource.project,
        projectDir: projectDir,
        homeDir: homeDir,
      );
      expect(file, '$projectDir/.fah/config.yaml');
      expect(
        resolveAppContextWindowCap(
          projectDir: projectDir,
          homeDir: homeDir,
        ).source,
        AppContextCapSource.project,
      );
    });

    test('a below-floor cap is refused by the shared validator', () async {
      await expectLater(
        writeAppContextWindowCap(
          1024,
          layer: AppContextCapSource.user,
          homeDir: homeDir,
        ),
        throwsA(isA<ConfigException>()),
      );
      expect(File('$homeDir/.fah/config.yaml').existsSync(), isFalse);
    });

    test(
      'clear removes the key; sibling agent keys survive byte-for-byte',
      () async {
        writeUser(
          '# keep me\nagent:\n  contextWindowCap: 65536\n  misuseBreaker: '
          'false\n',
        );
        final file = await writeAppContextWindowCap(
          null,
          layer: AppContextCapSource.user,
          homeDir: homeDir,
        );
        expect(file, '$homeDir/.fah/config.yaml');
        final edited = File(file).readAsStringSync();
        expect(edited, contains('# keep me'));
        expect(edited, contains('misuseBreaker: false'));
        expect(edited, isNot(contains('contextWindowCap')));
        // The file still parses and validates (the boot would accept it).
        final doc = loadYaml(edited) as YamlMap;
        validateAgentSection(doc['agent']);
      },
    );

    test('clearing an absent cap is a quiet no-op', () async {
      writeUser('provider: openai\n');
      await writeAppContextWindowCap(
        null,
        layer: AppContextCapSource.user,
        homeDir: homeDir,
      );
      expect(
        File('$homeDir/.fah/config.yaml').readAsStringSync(),
        'provider: openai\n',
      );
    });

    test('none is not a writable layer', () {
      expect(
        () => writeAppContextWindowCap(
          200000,
          layer: AppContextCapSource.none,
          homeDir: homeDir,
        ),
        throwsArgumentError,
      );
    });

    test('project layer without a projectDir is refused', () {
      // gh-2479 review: a project-layer write without a directory would
      // interpolate `null/.fah/config.yaml` and fall back to the user
      // file — a wrong-scope write. The guard fires BEFORE any path is
      // built, on both the set and the clear path.
      expect(
        () => writeAppContextWindowCap(
          200000,
          layer: AppContextCapSource.project,
          homeDir: homeDir,
        ),
        throwsArgumentError,
      );
      expect(
        () => writeAppContextWindowCap(
          null,
          layer: AppContextCapSource.project,
          homeDir: homeDir,
        ),
        throwsArgumentError,
      );
      expect(
        File('$homeDir/.fah/config.yaml').existsSync(),
        isFalse,
        reason: 'the refusal never touches the user file',
      );
    });
  });

  group('per-model window override', () {
    test('write → persisted in the user config → read back', () async {
      final file = await writeAppModelWindowOverride(
        'aiin',
        'aiin/glm-5',
        200000,
        homeDir: homeDir,
      );
      expect(file, '$homeDir/.fah/config.yaml');
      final doc = loadYaml(File(file).readAsStringSync()) as YamlMap;
      final pinned =
          ((doc['models'] as YamlMap)['overrides'] as YamlMap)['aiin']
              as YamlMap;
      expect(((pinned['aiin/glm-5'] as YamlMap)['contextWindow']), 200000);
      expect(
        loadAppModelWindowOverride('aiin', 'aiin/glm-5', homeDir: homeDir),
        200000,
      );
      // The parser accepts the edited section (the boot will too).
      ModelsConfig.fromYaml(doc['models']);
    });

    test(
      'an override for one model leaves other overrides untouched',
      () async {
        writeUser(
          'models:\n  overrides:\n    kimi:\n      kimi/m1:\n        '
          'contextWindow: 131072\n',
        );
        await writeAppModelWindowOverride(
          'aiin',
          'aiin/glm-5',
          200000,
          homeDir: homeDir,
        );
        final doc =
            loadYaml(File('$homeDir/.fah/config.yaml').readAsStringSync())
                as YamlMap;
        final overrides = (doc['models'] as YamlMap)['overrides'] as YamlMap;
        expect(
          ((overrides['kimi'] as YamlMap)['kimi/m1']
              as YamlMap)['contextWindow'],
          131072,
        );
        expect(overrides['aiin'], isNotNull);
      },
    );

    test('a below-floor override is refused and writes NOTHING', () async {
      writeUser('# keep\nmodels:\n  overrides: {}\n');
      await expectLater(
        writeAppModelWindowOverride(
          'aiin',
          'aiin/glm-5',
          1024,
          homeDir: homeDir,
        ),
        throwsA(isA<ConfigException>()),
      );
      expect(
        File('$homeDir/.fah/config.yaml').readAsStringSync(),
        '# keep\nmodels:\n  overrides: {}\n',
        reason: 'the refused write left the file byte-for-byte',
      );
    });

    test('clear removes the pin; sibling pins survive', () async {
      writeUser(
        'models:\n  overrides:\n    kimi:\n      kimi/m1:\n        '
        'contextWindow: 131072\n',
      );
      await writeAppModelWindowOverride(
        'aiin',
        'aiin/glm-5',
        null,
        homeDir: homeDir,
      );
      final doc =
          loadYaml(File('$homeDir/.fah/config.yaml').readAsStringSync())
              as YamlMap;
      final overrides = (doc['models'] as YamlMap)['overrides'] as YamlMap;
      expect(overrides['aiin'], isNull);
      expect(
        ((overrides['kimi'] as YamlMap)['kimi/m1'] as YamlMap)['contextWindow'],
        131072,
      );
    });

    test('clear on a models-less config is a quiet no-op', () async {
      writeUser('provider: openai\n');
      await writeAppModelWindowOverride(
        'aiin',
        'aiin/glm-5',
        null,
        homeDir: homeDir,
      );
      expect(
        File('$homeDir/.fah/config.yaml').readAsStringSync(),
        'provider: openai\n',
      );
    });
  });

  group('web stub semantics', () {
    test('unsupported: uncapped, no overrides, writes refuse', () {
      expect(web_stub.appContextWindowConfigSupported, isFalse);
      expect(
        web_stub.resolveAppContextWindowCap(projectDir: '/any').source,
        AppContextCapSource.none,
      );
      expect(web_stub.loadAppCapabilityOverrides(), isNull);
      expect(
        () => web_stub.writeAppContextWindowCap(
          200000,
          layer: AppContextCapSource.user,
        ),
        throwsUnsupportedError,
      );
      expect(
        () => web_stub.writeAppModelWindowOverride('aiin', 'm', 200000),
        throwsUnsupportedError,
      );
    });
  });
}
