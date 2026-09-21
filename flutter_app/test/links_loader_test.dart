// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The app-side `links:` resolution (issue #691): the Get banner's URLs
/// come from the SAME section the CLI reads — user overrides win, a
/// broken file never bricks the app (defaults + note), and the envelope
/// carries the section's tolerant-parse notes. These tests run against
/// the IO loader (dart:io temp homes); the web-stub contract (defaults,
/// no notes) is pinned in the same file — the stub is pure.
library;

import 'dart:io';

import 'package:fa/services/links_loader_io.dart';
import 'package:fa/services/links_loader_stub.dart' as web;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('fa_links_home');
  });

  tearDown(() => home.deleteSync(recursive: true));

  Future<void> writeConfig(String yaml) async {
    final dir = Directory('${home.path}/.fah');
    await dir.create(recursive: true);
    await File('${dir.path}/config.yaml').writeAsString(yaml);
  }

  test('absent config resolves the baked-in defaults', () {
    final resolution = resolveAppLinks(homeDir: home.path);
    expect(resolution.links.isDefault, isTrue);
    expect(resolution.notes, isEmpty);
  });

  test('a user override wins (one change, every surface — AC1)', () async {
    await writeConfig(
      'provider: openai-completions\n'
      'links:\n'
      '  appstore: https://apps.apple.com/us/app/fa/id321\n',
    );
    final resolution = resolveAppLinks(homeDir: home.path);
    expect(resolution.links.appstore, 'https://apps.apple.com/us/app/fa/id321');
    expect(resolution.links.testflight, defaultTestFlightUrl);
    expect(resolution.notes, isEmpty);
  });

  test('an invalid section falls back to the defaults with a note', () async {
    await writeConfig(
      'provider: openai-completions\n'
      'links:\n'
      '  appstore: not-a-url\n',
    );
    final resolution = resolveAppLinks(homeDir: home.path);
    expect(resolution.links.isDefault, isTrue);
    expect(resolution.notes, isNotEmpty);
    expect(resolution.notes.single, contains('fell back to the defaults'));
  });

  test('the banner master switch travels with the section', () async {
    await writeConfig('links:\n  banner: false\n');
    final resolution = resolveAppLinks(homeDir: home.path);
    expect(resolution.links.banner, isFalse);
  });

  test('tolerant unknown keys surface as notes, not fallbacks', () async {
    await writeConfig('links:\n  docs: https://fa1.dev/docs\n');
    final resolution = resolveAppLinks(homeDir: home.path);
    expect(resolution.links.isDefault, isTrue);
    expect(resolution.notes, isNotEmpty);
    expect(resolution.notes.single, contains('links.docs'));
  });

  test('the web stub resolves the defaults with no notes', () {
    final resolution = web.resolveAppLinks();
    expect(resolution.links.isDefault, isTrue);
    expect(resolution.notes, isEmpty);
  });
}
