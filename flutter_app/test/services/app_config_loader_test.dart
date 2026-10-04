// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The IO app-config loader (issue #1078): real files through the CLI's
/// parsers — absent config is silence, unreadable/malformed degrades to a
/// warning naming the file (E2/AC7), and the project pair rides the same
/// read when a project dir is mounted (OQ2).
library;

import 'dart:io';

import 'package:fa/services/app_config_loader.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory home;
  late Directory project;

  setUp(() {
    home = Directory.systemTemp.createTempSync('fah-home');
    project = Directory.systemTemp.createTempSync('fah-project');
  });
  tearDown(() {
    home.deleteSync(recursive: true);
    project.deleteSync(recursive: true);
  });

  File fileOf(Directory dir, String rel, String body) {
    final f = File('${dir.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(body);
    return f;
  }

  test('no config at all is silence: defaults, no warnings', () {
    final sections = loadAppFahConfig(
      homeDir: home.path,
      projectDir: project.path,
    );
    expect(sections, isNotNull);
    expect(sections!.roles, isNull);
    expect(sections.ttsr, isNull);
    expect(sections.redact, isNull);
    expect(sections.providerTimeouts, isNull);
    expect(sections.warnings, isEmpty);
    expect(sections.userDoc, isNull);
  });

  test('a nonexistent home degrades to defaults silently (E2)', () {
    final sections = loadAppFahConfig(homeDir: '${home.path}/nope');
    expect(sections, isNotNull);
    expect(sections!.warnings, isEmpty);
    expect(sections.userDoc, isNull);
  });

  test('every section resolves through the real files', () {
    fileOf(
      home,
      '.fah/config.yaml',
      '''
roles:
  smol:
    - p/smol-1
  slow:
    - p/slow-1
ttsr:
  settings:
    enabled: true
  rules:
    - name: no-secrets
      pattern: 'hunter2'
      body: Never echo passwords.
redact:
  enabled: true
  blockMode: true
providerTimeouts:
  connectTimeoutMs: 42000
agent:
  mode: omp
''',
    );
    final sections = loadAppFahConfig(
      homeDir: home.path,
      projectDir: project.path,
    )!;
    expect(sections.roles!.roles.keys, ['smol', 'slow']);
    expect(sections.ttsr!.rules.single.name, 'no-secrets');
    expect(sections.redact!.blockMode, isTrue);
    expect(sections.providerTimeouts!.connect, const Duration(seconds: 42));
    expect(sections.loadMode, AgentLoadMode.omp);
    expect(sections.warnings, isEmpty);
  });

  test('project scope: .fah/config.yaml tools + rules.yaml merge in', () {
    fileOf(
      project,
      '.fah/config.yaml',
      'tools:\n  web_search: false\n',
    );
    fileOf(
      project,
      '.fah/rules.yaml',
      'rules:\n  - name: proj-rule\n    pattern: proj\n    body: proj body\n',
    );
    fileOf(
      home,
      '.fah/config.yaml',
      '''
ttsr:
  rules:
    - name: user-rule
      pattern: user
      body: user body
''',
    );
    final sections = loadAppFahConfig(
      homeDir: home.path,
      projectDir: project.path,
    )!;
    expect(sections.projectTools.tools, {'web_search': false});
    // Project rules first (the CLI merge order).
    expect(
      sections.ttsr!.rules.map((r) => r.name),
      ['proj-rule', 'user-rule'],
    );
  });

  test('malformed yaml degrades: warning names the file, boot unblocked', () {
    fileOf(home, '.fah/config.yaml', '\troles: bad\ttab-indent');
    final sections = loadAppFahConfig(
      homeDir: home.path,
      projectDir: project.path,
    )!;
    expect(sections.roles, isNull);
    expect(sections.warnings, hasLength(1));
    // AC7: the warning names file + section.
    expect(sections.warnings.single, contains('roles'));
    expect(sections.warnings.single, contains(home.path));
  });

  test('a directory at the config path degrades silently (mount gate)',
      () {
    // OQ2: existsSync is the mount probe — a non-file path reads as an
    // absent scope, no noise.
    Directory('${home.path}/.fah/config.yaml').createSync(recursive: true);
    final sections = loadAppFahConfig(
      homeDir: home.path,
      projectDir: project.path,
    )!;
    expect(sections.redact, isNull);
    expect(sections.warnings, isEmpty);
  });
}
