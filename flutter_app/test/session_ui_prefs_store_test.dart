@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fa/services/session_ui_prefs_store.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late LocalExecutionEnv env;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fah_ui_prefs_test');
    env = LocalExecutionEnv(cwd: tmp.path);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('toggle writes through and a fresh store (app restart) reads the '
      'same state', () async {
    final store = await SessionUiPrefsStore.load(env);
    await store.setExpanded('parent-1', true);
    await store.setExpanded('parent-2', false);

    // Same instance reflects the toggles.
    expect(store.expandedParents, {'parent-1'});
    expect(store.collapsedParents, {'parent-2'});

    // A restart: a NEW store over the same env sees the same state.
    final revived = await SessionUiPrefsStore.load(env);
    expect(revived.expandedParents, {'parent-1'});
    expect(revived.collapsedParents, {'parent-2'});
  });

  test('re-toggling moves the parent between the sets instead of '
      'accumulating stale entries', () async {
    final store = await SessionUiPrefsStore.load(env);
    await store.setExpanded('p', true);
    await store.setExpanded('p', false);
    expect(store.expandedParents, isEmpty);
    expect(store.collapsedParents, {'p'});
    await store.setExpanded('p', true);
    expect(store.expandedParents, {'p'});
    expect(store.collapsedParents, isEmpty);
  });

  test('a corrupt or foreign-version file yields an empty store (boot '
      'never breaks)', () async {
    await env.writeFile(
      '${env.cwd}/${SessionUiPrefsStore.fileName}',
      '{"version": 99, "expandedParents": ["x"]}',
    );
    final store = await SessionUiPrefsStore.load(env);
    expect(store.expandedParents, isEmpty);
    expect(store.collapsedParents, isEmpty);

    await env.writeFile(
      '${env.cwd}/${SessionUiPrefsStore.fileName}',
      'not json at all',
    );
    final store2 = await SessionUiPrefsStore.load(env);
    expect(store2.expandedParents, isEmpty);
  });

  test('inMemory keeps state without touching the filesystem', () async {
    final store = SessionUiPrefsStore.inMemory();
    await store.setExpanded('p', false);
    expect(store.collapsedParents, {'p'});
    // No file was written next to the (real) cwd.
    final file = File('${tmp.path}/${SessionUiPrefsStore.fileName}');
    expect(file.existsSync(), isFalse);
  });

  test('sidebar width persists and a fresh store reads it back (issue '
      '#426 item 4)', () async {
    final store = await SessionUiPrefsStore.load(env);
    expect(store.sidebarWidth, isNull); // default until the user drags
    await store.setSidebarWidth(360);

    final revived = await SessionUiPrefsStore.load(env);
    expect(revived.sidebarWidth, 360);
  });

  test('sidebar width is clamped on write (drag handle + hand-edited '
      'files)', () async {
    final store = await SessionUiPrefsStore.load(env);
    await store.setSidebarWidth(50);
    expect(store.sidebarWidth, SessionUiPrefsStore.minSidebarWidth);
    await store.setSidebarWidth(9999);
    expect(store.sidebarWidth, SessionUiPrefsStore.maxSidebarWidth);
  });

  test('the persisted document is versioned JSON listing both sets', () async {
    final store = await SessionUiPrefsStore.load(env);
    await store.setExpanded('p1', true);
    await store.setExpanded('p2', false);
    final text =
        (await env.readTextFile('${env.cwd}/${SessionUiPrefsStore.fileName}'))
            .valueOrNull!;
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    expect(decoded['version'], SessionUiPrefsStore.version);
    expect(decoded['expandedParents'], ['p1']);
    expect(decoded['collapsedParents'], ['p2']);
  });
}
