// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #287 — the structured compaction engine is the DEFAULT, classic
/// is the in-settings rollback:
/// - AC1/UT-resolve: the app resolution matrix (no config → structured;
///   user classic → classic; project overrides user).
/// - AC2/IT-settings: the picker shows the effective engine + source
///   layer; switching writes the correct yaml layer SURGICALLY (an
///   unrelated comment survives byte-for-byte — the #221 lesson).
/// - AC4/UT-migration: configs without a compaction section resolve to
///   structured and are never mutated by reads.
/// - AC5/UT-web: the web stub semantics (no config source → structured
///   default; not supported; writes refused).
library;

import 'dart:io';

import 'package:fa/services/compaction_engine_loader.dart';
// The stub is plain Dart (no dart:io) — imported directly to pin the web
// semantics regardless of the platform the test runs on.
import 'package:fa/services/compaction_engine_loader_stub.dart'
    as web_stub;
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late String projectDir;
  late String homeDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fa_comp287app_');
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

  group('AC1/AC4 — app resolution matrix (UT-resolve/UT-migration)', () {
    test('no config anywhere → structured (the 2.0 default)', () {
      final r = resolveAppCompactionEngine(
        projectDir: projectDir,
        homeDir: homeDir,
      );
      expect(r.engine, CompactionEngine.structured);
      expect(r.source, AppCompactionEngineSource.fallback);
      // Configs without a compaction section are not mutated by reads.
      expect(
        File('$projectDir/.fah/config.yaml').existsSync(),
        isFalse,
        reason: 'no file was created by a read',
      );
    });

    test('user-yaml classic → classic from the user layer', () {
      writeUser('compaction:\n  engine: classic\n');
      final r = resolveAppCompactionEngine(
        projectDir: projectDir,
        homeDir: homeDir,
      );
      expect(r.engine, CompactionEngine.classic);
      expect(r.source, AppCompactionEngineSource.user);
    });

    test('project yaml overrides the user yaml (both directions)', () {
      writeUser('compaction:\n  engine: classic\n');
      writeProject('compaction:\n  engine: structured\n');
      expect(
        resolveAppCompactionEngine(projectDir: projectDir, homeDir: homeDir)
            .source,
        AppCompactionEngineSource.project,
      );
      writeProject('compaction:\n  engine: classic\n');
      writeUser('compaction:\n  engine: structured\n');
      final r = resolveAppCompactionEngine(
        projectDir: projectDir,
        homeDir: homeDir,
      );
      expect(r.engine, CompactionEngine.classic);
      expect(r.source, AppCompactionEngineSource.project);
    });

    test('existing file with other keys stays untouched by a read', () {
      const yaml = '# treasured comment\nprovider: openai\n';
      writeUser(yaml);
      resolveAppCompactionEngine(projectDir: projectDir, homeDir: homeDir);
      expect(File('$homeDir/.fah/config.yaml').readAsStringSync(), yaml);
    });
  });

  group('AC2 — switching writes the correct layer surgically', () {
    test('project layer: a comment survives the engine write byte-for-byte',
        () async {
      const yaml = '# treasured comment\nprovider: openai\nmodel: gpt-x\n';
      writeProject(yaml);
      final file = await writeAppCompactionEngine(
        CompactionEngine.classic,
        layer: AppCompactionEngineSource.project,
        projectDir: projectDir,
        homeDir: homeDir,
      );
      expect(file, '$projectDir/.fah/config.yaml');
      final edited = File(file).readAsStringSync();
      expect(edited, contains('# treasured comment'));
      expect(edited, contains('provider: openai'));
      expect(edited, contains('engine: classic'));
      // The write resolved: classic now wins from the project layer.
      final r = resolveAppCompactionEngine(
        projectDir: projectDir,
        homeDir: homeDir,
      );
      expect(r.engine, CompactionEngine.classic);
      expect(r.source, AppCompactionEngineSource.project);
    });

    test('user layer: a missing file is created with the minimal section',
        () async {
      final file = await writeAppCompactionEngine(
        CompactionEngine.classic,
        layer: AppCompactionEngineSource.user,
        projectDir: projectDir,
        homeDir: homeDir,
      );
      expect(file, '$homeDir/.fah/config.yaml');
      expect(
        resolveAppCompactionEngine(projectDir: projectDir, homeDir: homeDir)
            .engine,
        CompactionEngine.classic,
        reason: 'the explicit rollback choice is persisted and re-read',
      );
    });

    test('fallback is not a writable layer', () {
      expect(
        () => writeAppCompactionEngine(
          CompactionEngine.classic,
          layer: AppCompactionEngineSource.fallback,
        ),
        throwsArgumentError,
      );
    });
  });

  group('AC5 — web stub semantics (UT-web)', () {
    test('no config source → structured default, unsupported, writes refuse',
        () {
      expect(web_stub.appCompactionConfigSupported, isFalse);
      expect(web_stub.loadAppCompactionEngine('/any'), isNull);
      final r = web_stub.resolveAppCompactionEngine(projectDir: '/any');
      expect(r.engine, CompactionEngine.structured);
      expect(r.source, AppCompactionEngineSource.fallback);
      expect(
        () => web_stub.writeAppCompactionEngine(
          CompactionEngine.classic,
          layer: AppCompactionEngineSource.user,
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('AC2 — the settings section (IT-settings)', () {
    AppCompactionEngineResolution fakeResolve(
      CompactionEngine engine,
      AppCompactionEngineSource source,
    ) => AppCompactionEngineResolution(engine, source);

    Future<void> pump(
      WidgetTester tester, {
      required AppCompactionEngineResolution resolution,
      bool supported = true,
      AppCompactionEngineResolution Function({
        String? projectDir,
        String? homeDir,
      })?
      resolve,
      Future<String> Function(
        CompactionEngine engine, {
        required AppCompactionEngineSource layer,
        String? projectDir,
        String? homeDir,
      })?
      write,
    }) {
      resolve ??= ({projectDir, homeDir}) => resolution;
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CompactionSection(
                projectDir: '/proj',
                supported: supported,
                resolve: resolve,
                write: write,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('renders the effective engine and its source layer', (
      tester,
    ) async {
      await pump(
        tester,
        resolution: fakeResolve(
          CompactionEngine.structured,
          AppCompactionEngineSource.fallback,
        ),
      );
      expect(find.text('Compaction'), findsOneWidget);
      expect(
        find.text('Structured (recommended)'),
        findsOneWidget,
        reason: 'the dropdown seeds with the effective engine',
      );
      expect(
        find.textContaining('no compaction setting in any config'),
        findsOneWidget,
        reason: 'the fallback source layer is shown',
      );
      expect(
        find.textContaining('requires a configured model for the judge pass'),
        findsOneWidget,
        reason: 'honest tradeoff copy (E1: no health-check claim)',
      );
    });

    testWidgets('a user-layer classic shows the user source caption', (
      tester,
    ) async {
      await pump(
        tester,
        resolution: fakeResolve(
          CompactionEngine.classic,
          AppCompactionEngineSource.user,
        ),
      );
      expect(find.text('Classic (legacy 1.0)'), findsOneWidget);
      expect(
        find.textContaining('user ~/.fah/config.yaml'),
        findsOneWidget,
      );
    });

    testWidgets('switching to classic writes the project layer and confirms', (
      tester,
    ) async {
      final writes = <(CompactionEngine, AppCompactionEngineSource)>[];
      await pump(
        tester,
        resolution: fakeResolve(
          CompactionEngine.structured,
          AppCompactionEngineSource.fallback,
        ),
        write: (engine, {required layer, projectDir, homeDir}) async {
          writes.add((engine, layer));
          return '/proj/.fah/config.yaml';
        },
      );
      await tester.tap(find.text('Structured (recommended)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Classic (legacy 1.0)').last);
      await tester.pumpAndSettle();
      expect(writes, [
        (CompactionEngine.classic, AppCompactionEngineSource.project),
      ], reason: 'a fresh choice lands in the project layer (fa config set '
          'scope); the snackbar names the file');
      expect(
        find.textContaining('applies at the next compaction'),
        findsOneWidget,
      );
    });

    testWidgets('a user-sourced choice is edited on the user layer', (
      tester,
    ) async {
      final writes = <(CompactionEngine, AppCompactionEngineSource)>[];
      await pump(
        tester,
        resolution: fakeResolve(
          CompactionEngine.classic,
          AppCompactionEngineSource.user,
        ),
        write: (engine, {required layer, projectDir, homeDir}) async {
          writes.add((engine, layer));
          return '/home/.fah/config.yaml';
        },
      );
      await tester.tap(find.text('Classic (legacy 1.0)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Structured (recommended)').last);
      await tester.pumpAndSettle();
      expect(writes, [
        (CompactionEngine.structured, AppCompactionEngineSource.user),
      ], reason: 'the layer that currently wins is edited in place, never '
          'shadowed');
    });

    testWidgets('web: disabled with a note instead of a picker', (
      tester,
    ) async {
      await pump(
        tester,
        supported: false,
        resolution: fakeResolve(
          CompactionEngine.structured,
          AppCompactionEngineSource.fallback,
        ),
      );
      expect(find.byType(DropdownButtonFormField<CompactionEngine>), findsNothing);
      expect(
        find.textContaining('Not configurable on the web'),
        findsOneWidget,
      );
      expect(find.text('Compaction'), findsOneWidget);
    });
  });
}
