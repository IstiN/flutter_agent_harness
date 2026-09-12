// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fa/apps/js_theme_bridge_host.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/services/theme_pack_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Host-side IT-consent for `jsr.fa.theme.*` (issue #169 AC4): the bridge
/// answers list/current with declarative descriptors, every apply rides the
/// injected consent prompt (grant moves the app theme, deny is a clean
/// no-op), prompts serialize (E3), and the engine bootstrap offers exactly
/// list/current/apply — an app looking for `theme.install` finds no such
/// API (byte-scan). The JS-side plumbing (`jsr.fa.call` round-trip and the
/// permission-flag gate) shares the machinery exercised by
/// `js_app_emit_test.dart`/`js_app_keys_test.dart` (engine-backed suites).
void main() {
  late ThemePackStore store;
  late ThemeController controller;

  setUp(() async {
    final env = MemoryExecutionEnv();
    store = await ThemePackStore.load(env);
    final themeJson = jsonEncode({
      'name': 'Forest Walk',
      'version': '1.0.0',
      'colors': {
        'dark': {'accent': '#2E7D32'},
      },
    });
    final archive = Archive()
      ..add(ArchiveFile.bytes('theme.json', utf8.encode(themeJson)));
    final result = await store.installFromZip(
      Uint8List.fromList(ZipEncoder().encode(archive)),
    );
    expect(result.spec, isNotNull, reason: result.reasons.join('\n'));
    controller = ThemeController.inMemory();
  });

  FaThemeBridgeHost host({required bool Function() answer}) =>
      FaThemeBridgeHost(
        store: store,
        controller: controller,
        prompt: (_) async => answer(),
      );

  test('list answers with the declarative descriptor', () async {
    final packs = await host(answer: () => true).listPacks();
    expect(packs, [
      {
        'id': 'forest-walk',
        'name': 'Forest Walk',
        'version': '1.0.0',
        'hasWallpaper': false,
        'contrastWarnings': const <String>[],
      },
    ]);
  });

  test('current is null before any apply, the pack after', () async {
    final bridge = host(answer: () => true);
    expect((await bridge.currentPack())?['id'], isNull);
    await bridge.applyPack('forest-walk');
    expect((await bridge.currentPack())?['id'], 'forest-walk');
  });

  test('apply granted moves the app theme', () async {
    final outcome = await host(answer: () => true).applyPack('forest-walk');
    expect(outcome['applied'], true);
    expect((outcome['pack'] as Map)['id'], 'forest-walk');
    expect(controller.packId, 'forest-walk');
  });

  test('apply denied is a clean no-op (AC4: deny = no-op, no crash)', () async {
    final outcome = await host(answer: () => false).applyPack('forest-walk');
    expect(outcome, {'applied': false, 'reason': 'denied'});
    expect(controller.packId, isNull);
  });

  test('an unknown pack id rejects with the ids hint', () async {
    await expectLater(
      host(answer: () => true).applyPack('nope'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('jsr.fa.theme.list()'),
        ),
      ),
    );
  });

  test(
    'E3: concurrent applies serialize their prompts, last grant wins',
    () async {
      final order = <String>[];
      final bridge = FaThemeBridgeHost(
        store: store,
        controller: controller,
        prompt: (_) async {
          order.add('prompt');
          // Simulate a slow dialog: the second apply must wait for it.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return true;
        },
      );
      final results = await Future.wait([
        bridge.applyPack('forest-walk'),
        bridge.applyPack('forest-walk'),
      ]);
      expect(results.map((r) => r['applied']), everyElement(true));
      expect(order, hasLength(2));
      expect(controller.packId, 'forest-walk');
    },
  );

  test('byte-scan: the engine bootstrap exposes exactly list/current/apply, '
      'no theme.install (AC4)', () {
    final engine = File('lib/apps/js_app_engine.dart').readAsStringSync();
    expect(
      engine.contains('theme.install'),
      isFalse,
      reason: 'an app must never find an install surface on the bridge',
    );
    // The one jsr.fa.theme surface the bootstrap installs:
    expect(engine, contains('jsr.fa.theme = {'));
    expect(
      RegExp(
        "jsr\\.fa\\.call\\('theme\\.([a-z]+)",
      ).allMatches(engine).map((m) => m.group(1)),
      unorderedEquals(['list', 'current', 'apply']),
    );
  });
}
