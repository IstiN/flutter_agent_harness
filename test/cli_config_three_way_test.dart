/// gh-2422: the REPL's `persistConfig` saves the WHOLE config it loaded at
/// boot, so with several long-lived REPLs the last saver silently reverts
/// roles/providers/keys another process edited meanwhile. The save merges
/// three ways now: only the top-level keys this process changed vs its
/// loaded baseline are written over the current disk state; project-capable
/// sections that live in `<project>/.fah/config.yaml` are written THERE
/// (and a `--global` boot flag forces the global file again).
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

final class Harness {
  Harness(this.tmp) : proj = Directory('${tmp.path}/proj');

  final Directory tmp;
  final Directory proj;

  File get global => File('${tmp.path}/.fah/config.yaml');
  File get project => File('${proj.path}/.fah/config.yaml');

  void seedGlobal(String text) {
    global
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  void seedProject(String text) {
    project
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }
}

void main() {
  group('saveCliConfig three-way merge (gh-2422)', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-gh2422-merge-');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('a stale-baseline save keeps the other process\'s section and '
        'writes only the one this process changed', () async {
      final h = Harness(tmp);
      h.seedGlobal('mode: code\napprovalMode: yolo\n');
      // Process A boots; process B switches the mode and saves.
      final baseline = loadCliConfig(tmp.path);
      await saveCliConfig(
        tmp.path,
        loadCliConfig(tmp.path).copyWith(mode: 'architect'),
      );
      expect(loadCliConfig(tmp.path).mode, 'architect');
      // Process A saves ITS change (approval mode) from its stale
      // baseline — the mode B wrote must survive.
      await saveCliConfig(
        tmp.path,
        baseline.copyWith(approvalMode: 'unattended'),
        base: baseline,
      );
      final onDisk = loadCliConfig(tmp.path);
      expect(onDisk.mode, 'architect', reason: 'B\'s edit survives A\'s save');
      expect(onDisk.approvalMode, 'unattended', reason: 'A\'s edit lands');
    });

    test('a fully unchanged three-way save is a no-op', () async {
      final h = Harness(tmp);
      h.seedGlobal('mode: architect\napprovalMode: write\n');
      final baseline = loadCliConfig(tmp.path);
      final before = h.global.readAsStringSync();
      final beforeStat = h.global.statSync();
      await saveCliConfig(tmp.path, baseline.copyWith(), base: baseline);
      expect(h.global.readAsStringSync(), before);
      expect(
        h.global.statSync().modified,
        beforeStat.modified,
        reason: 'an unchanged save must not touch the file (gh-1572 rule)',
      );
    });

    test('every section the process did not change keeps the disk value, '
        'the changed ones land (multi-section combo)', () async {
      final h = Harness(tmp);
      h.seedGlobal('''
mode: code
approvalMode: yolo
allowedTools:
  - web_fetch
roles:
  smol:
    - openai/gpt-4o-mini
''');
      final baseline = loadCliConfig(tmp.path);
      // This process changed mode AND the allowed tools; roles untouched.
      await saveCliConfig(
        tmp.path,
        baseline.copyWith(
          mode: 'review',
          allowedTools: ['web_fetch', 'web_search'],
        ),
        base: baseline,
      );
      final onDisk = loadCliConfig(tmp.path);
      expect(onDisk.mode, 'review');
      expect(onDisk.allowedTools, ['web_fetch', 'web_search']);
      expect(
        onDisk.modelRoles?.toYaml(),
        baseline.modelRoles?.toYaml(),
        reason: 'roles were not changed by this process — disk wins',
      );
    });

    test('a section this process REMOVED is deleted from disk — the '
        'backstop must not resurrect it', () async {
      final h = Harness(tmp);
      h.seedGlobal('''
provider: openai-completions
model: openai/gpt-4o-mini
baseUrl: https://openrouter.ai/api/v1
models:
  slots:
    vision:
      providerKind: openai-completions
      baseUrl: https://api.openai.com/v1
      modelId: gpt-4o
''');
      final baseline = loadCliConfig(tmp.path);
      expect(baseline.models, isNotNull);
      // Empty render = removal semantics for `models:` (saveCliConfig doc).
      await saveCliConfig(
        tmp.path,
        baseline.copyWith(models: ModelsConfig()),
        base: baseline,
      );
      final onDisk = loadCliConfig(tmp.path);
      expect(onDisk.models, isNull, reason: 'removed stays removed');
      expect(onDisk.modelId, 'openai/gpt-4o-mini', reason: 'rest survives');
    });

    test('the legacy call shape (no base) keeps caller-wins whole-save '
        'semantics', () async {
      final h = Harness(tmp);
      h.seedGlobal('mode: architect\n');
      await saveCliConfig(tmp.path, CliConfig(mode: 'code'));
      expect(loadCliConfig(tmp.path).mode, 'code');
    });
  });

  group('saveCliConfig project-file targeting (gh-2422)', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-gh2422-proj-');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('a changed project section living in the project file lands '
        'there, byte-surgically, and not in the global file', () async {
      final h = Harness(tmp);
      h.seedGlobal('provider: openai-completions\ncube:\n  enabled: true\n');
      h.seedProject(
        'memory:\n  projectPath: ./memory\ncube:\n'
        '  enabled: true\n  config: strict.yaml\n',
      );
      final baseline = loadCliConfig(tmp.path);
      // The session switched the cube default (/cube use other).
      await saveCliConfig(
        tmp.path,
        baseline.copyWith(
          cube: const CubeSettings(enabled: true, configPath: 'other.yaml'),
        ),
        base: baseline,
        projectDir: h.proj.path,
      );
      expect(
        h.project.readAsStringSync(),
        'memory:\n  projectPath: ./memory\ncube:\n'
        '  config: other.yaml\n',
        reason: 'only the cube block changed, in place',
      );
      final global = loadCliConfig(tmp.path);
      expect(
        global.cube?.configPath,
        isNull,
        reason: 'the global copy is shadowed, never re-rendered',
      );
      expect(global.providerKind, 'openai-completions');
    });

    test('a changed section the project file does not carry still lands '
        'in the global file', () async {
      final h = Harness(tmp);
      h.seedGlobal('mode: code\n');
      h.seedProject('memory:\n  projectPath: ./memory\n');
      final baseline = loadCliConfig(tmp.path);
      await saveCliConfig(
        tmp.path,
        baseline.copyWith(mode: 'architect'),
        base: baseline,
        projectDir: h.proj.path,
      );
      expect(loadCliConfig(tmp.path).mode, 'architect');
      expect(
        h.project.readAsStringSync(),
        'memory:\n  projectPath: ./memory\n',
      );
    });

    test('forceGlobal writes the project section to the global file and '
        'leaves the project file untouched', () async {
      final h = Harness(tmp);
      h.seedGlobal('cube:\n  enabled: true\n');
      h.seedProject('cube:\n  enabled: true\n  config: strict.yaml\n');
      final baseline = loadCliConfig(tmp.path);
      await saveCliConfig(
        tmp.path,
        baseline.copyWith(
          cube: const CubeSettings(enabled: true, configPath: 'other.yaml'),
        ),
        base: baseline,
        projectDir: h.proj.path,
        forceGlobal: true,
      );
      expect(
        loadCliConfig(tmp.path).cube?.configPath,
        'other.yaml',
        reason: '--global forces the global file',
      );
      expect(
        h.project.readAsStringSync(),
        'cube:\n  enabled: true\n  config: strict.yaml\n',
      );
    });

    test('a changed tools section living in the project file lands there '
        '(combo: tools project-targeted, mode global)', () async {
      final h = Harness(tmp);
      h.seedGlobal('mode: code\ntools:\n  web_search: false\n');
      h.seedProject('tools:\n  web_search: false\n');
      final baseline = loadCliConfig(tmp.path);
      await saveCliConfig(
        tmp.path,
        baseline.copyWith(
          mode: 'architect',
          tools: const ToolsConfig(
            tools: {'web_search': false, 'mcp:fs': true},
          ),
        ),
        base: baseline,
        projectDir: h.proj.path,
      );
      expect(
        h.project.readAsStringSync(),
        contains('mcp:\n    fs: true'),
        reason: 'the live tools view lands in the file that wins',
      );
      expect(
        loadCliConfig(tmp.path).mode,
        'architect',
        reason: 'the user-only section still lands global',
      );
    });

    test('an unparseable project file falls back to the global '
        'destination without touching the broken file', () async {
      final h = Harness(tmp);
      h.seedGlobal('cube:\n  enabled: true\n');
      h.seedProject('cube: [broken\n');
      final baseline = loadCliConfig(tmp.path);
      await saveCliConfig(
        tmp.path,
        baseline.copyWith(
          cube: const CubeSettings(enabled: true, configPath: 'other.yaml'),
        ),
        base: baseline,
        projectDir: h.proj.path,
      );
      expect(loadCliConfig(tmp.path).cube?.configPath, 'other.yaml');
      expect(h.project.readAsStringSync(), 'cube: [broken\n');
    });

    test('a project dir equal to the home dir skips targeting (the '
        '"project" file IS the global file)', () async {
      final h = Harness(tmp);
      h.seedGlobal('cube:\n  enabled: true\n');
      final baseline = loadCliConfig(tmp.path);
      await saveCliConfig(
        tmp.path,
        baseline.copyWith(
          cube: const CubeSettings(enabled: true, configPath: 'other.yaml'),
        ),
        base: baseline,
        projectDir: tmp.path,
      );
      final text = h.global.readAsStringSync();
      expect('cube:'.allMatches(text), hasLength(1), reason: 'no duplication');
      expect(loadCliConfig(tmp.path).cube?.configPath, 'other.yaml');
    });

    test('a section this process REMOVED never deletes the project '
        'copy — the removal cleans the global file only', () async {
      final h = Harness(tmp);
      h.seedGlobal('tools:\n  web_search: false\n');
      h.seedProject(
        'memory:\n  projectPath: ./memory\n'
        'tools:\n  web_search: false\n',
      );
      final baseline = loadCliConfig(tmp.path);
      // The live global tools view emptied out — the render omits the
      // section, which is the removal form for `tools:`.
      await saveCliConfig(
        tmp.path,
        baseline.copyWith(tools: const ToolsConfig()),
        base: baseline,
        projectDir: h.proj.path,
      );
      expect(
        h.project.readAsStringSync(),
        'memory:\n  projectPath: ./memory\ntools:\n'
        '  web_search: false\n',
        reason: "the repo-traveling policy is not this session's to delete",
      );
      expect(
        h.global.readAsStringSync(),
        isNot(contains('web_search')),
        reason: 'the global file honors the removal',
      );
    });

    test('the upsert keeps column-0 comments around the section and an '
        'unrelated-only project file targets nothing', () async {
      final h = Harness(tmp);
      h.seedGlobal('cube:\n  enabled: true\n');
      h.seedProject(
        '# repo default sandbox\n'
        'cube:\n'
        '  config: strict.yaml\n'
        '# memory notes follow\n'
        'other: value\n',
      );
      final baseline = loadCliConfig(tmp.path);
      await saveCliConfig(
        tmp.path,
        baseline.copyWith(
          cube: const CubeSettings(enabled: true, configPath: 'other.yaml'),
        ),
        base: baseline,
        projectDir: h.proj.path,
      );
      final text = h.project.readAsStringSync();
      expect(text, contains('# repo default sandbox\n'));
      expect(text, contains('# memory notes follow\nother: value\n'));
      expect(text, contains('config: other.yaml'));
    });

    test(
      'an empty project file targets nothing (global destination)',
      () async {
        final h = Harness(tmp);
        h.seedGlobal('cube:\n  enabled: true\n');
        h.project
          ..createSync(recursive: true)
          ..writeAsStringSync('');
        final baseline = loadCliConfig(tmp.path);
        await saveCliConfig(
          tmp.path,
          baseline.copyWith(
            cube: const CubeSettings(enabled: true, configPath: 'other.yaml'),
          ),
          base: baseline,
          projectDir: h.proj.path,
        );
        expect(loadCliConfig(tmp.path).cube?.configPath, 'other.yaml');
        expect(h.project.readAsStringSync(), '');
      },
    );

    test(
      'no project file at all keeps the legacy global destination',
      () async {
        final h = Harness(tmp);
        h.seedGlobal('mode: code\n');
        final baseline = loadCliConfig(tmp.path);
        await saveCliConfig(
          tmp.path,
          baseline.copyWith(mode: 'architect'),
          base: baseline,
          projectDir: h.proj.path,
        );
        expect(loadCliConfig(tmp.path).mode, 'architect');
        expect(h.project.existsSync(), isFalse);
      },
    );
  });
}
