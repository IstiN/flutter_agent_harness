@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fa/services/subagent_parent_resolver.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Writes one session file directly under [dir] (the layout the sidebar
/// lists: `<sessionsRoot>/<encodedCwd>/<timestamp>_<id>.jsonl`), returning
/// its metadata as the listing sees it.
Future<SessionMetadata> writeSessionFile(
  Directory dir, {
  required String id,
  Map<String, dynamic> metadata = const {},
  List<String> extraLines = const [],
  DateTime? mtime,
}) async {
  final header = jsonEncode({
    'type': 'session',
    'version': 3,
    'id': id,
    'timestamp': '2026-09-14T12:00:00.000',
    'cwd': dir.path,
    'metadata': metadata,
  });
  final file = File(
    '${dir.path}/${mtime?.millisecondsSinceEpoch ?? 0}_$id.jsonl'.replaceAll(
      ':',
      '-',
    ),
  );
  await file.writeAsString(
    [header, ...extraLines].map((l) => '$l\n').join(),
    flush: true,
  );
  if (mtime != null) await file.setLastModified(mtime);
  return SessionMetadata(
    id: id,
    createdAt: DateTime.parse('2026-09-14T12:00:00.000'),
    cwd: dir.path,
    path: file.path,
    lastUpdatedAt: mtime,
    metadata: metadata,
  );
}

/// A parent transcript tail carrying a `subagent_registry` record whose
/// entries point at child session files (the shape both hosts' `fa`
/// processes append at turn boundaries).
String registryLine(Map<String, String> childIdByPath) {
  return jsonEncode({
    'type': 'custom',
    'id': 'reg1',
    'parentId': 'p1',
    'customType': 'subagent_registry',
    'data': [
      for (final entry in childIdByPath.entries)
        {'id': 'c-${entry.key}', 'sessionId': entry.value},
    ],
  });
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fah_resolver_test');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('resolves legacy children (empty header parent) from the parent '
      'transcript registry', () async {
    final parent = await writeSessionFile(
      dir,
      id: '0198-parent-0007',
      metadata: {'agent': 'fa'},
    );
    final childA = await writeSessionFile(dir, id: '0198-child-a', metadata: {
      'agent': 'subagent',
      'id': 'aaaa11',
      'parent': '',
    });
    final childB = await writeSessionFile(dir, id: '0198-child-b', metadata: {
      'agent': 'subagent',
      'id': 'bbbb22',
      'parent': '',
    });
    await writeSessionFile(dir, id: '0198-parent-0007', metadata: {
      'agent': 'fa',
    }, extraLines: [
      jsonEncode({'type': 'message'}),
      registryLine({childA.id: childA.path, childB.id: childB.path}),
    ]);

    final resolved = await SubagentParentResolver().resolve([
      parent,
      childA,
      childB,
    ]);

    expect(resolved[childA.id], parent.id);
    expect(resolved[childB.id], parent.id);
  });

  test('passes through fresh children whose header already names the '
      'parent (no scan needed)', () async {
    final parent = await writeSessionFile(
      dir,
      id: '0198-parent-0008',
      metadata: {'agent': 'fa'},
    );
    final child = await writeSessionFile(dir, id: '0198-child-c', metadata: {
      'agent': 'subagent',
      'id': 'cccc33',
      'parent': parent.id,
    });

    final resolved = await SubagentParentResolver().resolve([parent, child]);

    // The header link needs no registry: nothing to resolve, no parent
    // file read.
    expect(resolved, isEmpty);
  });

  test('matches a registry entry whose path drifted across roots by '
      'file basename', () async {
    final parent = await writeSessionFile(
      dir,
      id: '0198-parent-0009',
      metadata: {'agent': 'fa'},
    );
    final child = await writeSessionFile(dir, id: '0198-child-d', metadata: {
      'agent': 'subagent',
      'id': 'dddd44',
      'parent': '',
    });
    await writeSessionFile(dir, id: '0198-parent-0009', metadata: {
      'agent': 'fa',
    }, extraLines: [
      // The registry recorded the child under a DIFFERENT root prefix
      // (legacy per-project layout) — the basename still identifies it.
      registryLine({
        child.id:
            '/some/other/root/${child.path.split('/').last}',
      }),
    ]);

    final resolved = await SubagentParentResolver().resolve([parent, child]);

    expect(resolved[child.id], parent.id);
  });

  test('skips parents whose registry sits beyond the tail budget; the '
      'child stays unresolved (flat fallback)', () async {
    final parent = await writeSessionFile(
      dir,
      id: '0198-parent-0010',
      metadata: {'agent': 'fa'},
    );
    final child = await writeSessionFile(dir, id: '0198-child-e', metadata: {
      'agent': 'subagent',
      'id': 'eeee55',
      'parent': '',
    });
    // A transcript that keeps growing AFTER the registry was appended —
    // the record ends up deeper than the configured tail budget.
    final filler = List.generate(64, (i) => jsonEncode({
          'type': 'message',
          'padding': 'x' * 2048,
          'n': i,
        }));
    await writeSessionFile(dir, id: '0198-parent-0010', metadata: {
      'agent': 'fa',
    }, extraLines: [
      registryLine({child.id: child.path}),
      ...filler,
    ]);

    final resolved = await SubagentParentResolver(
      maxTailBytes: 8 * 1024,
    ).resolve([parent, child]);

    expect(resolved, isEmpty);
  });

  test('a corrupt registry line does not break resolution of other '
      'parents', () async {
    final goodParent = await writeSessionFile(
      dir,
      id: '0198-parent-0011',
      metadata: {'agent': 'fa'},
    );
    final child = await writeSessionFile(dir, id: '0198-child-f', metadata: {
      'agent': 'subagent',
      'id': 'ffff66',
      'parent': '',
    });
    await writeSessionFile(dir, id: '0198-parent-0011', metadata: {
      'agent': 'fa',
    }, extraLines: [
      registryLine({child.id: child.path}),
      // A crash mid-append leaves a truncated newest record — resolution
      // falls back to the previous complete one.
      '{"type":"custom","customType":"subagent_registry","data":[{"sessionId":',
    ]);

    final resolved = await SubagentParentResolver().resolve([
      goodParent,
      child,
    ]);

    expect(resolved[child.id], goodParent.id);
  });

  test('the newest parent wins when two registries claim the same child',
      () async {
    final older = await writeSessionFile(
      dir,
      id: '0198-parent-0012',
      metadata: {'agent': 'fa'},
      mtime: DateTime.parse('2026-09-14T12:00:00.000'),
    );
    final newer = await writeSessionFile(
      dir,
      id: '0198-parent-0013',
      metadata: {'agent': 'fa'},
      mtime: DateTime.parse('2026-09-15T12:00:00.000'),
    );
    final child = await writeSessionFile(dir, id: '0198-child-g', metadata: {
      'agent': 'subagent',
      'id': 'gggg77',
      'parent': '',
    });
    for (final parent in [older, newer]) {
      // Same mtime as the header write so the registry lands in the SAME
      // file (the filename embeds the mtime).
      await writeSessionFile(dir, id: parent.id, metadata: {
        'agent': 'fa',
      }, extraLines: [
        registryLine({child.id: child.path}),
      ], mtime: parent.lastUpdatedAt);
    }

    final resolved = await SubagentParentResolver().resolve([
      older,
      newer,
      child,
    ]);

    // The scan runs newest-first and stops at the first match.
    expect(resolved[child.id], newer.id);
  });

  test('a changed parent file re-resolves; an unchanged one is cached '
      '(no rescan on every sidebar reload)', () async {
    final parent = await writeSessionFile(
      dir,
      id: '0198-parent-0014',
      metadata: {'agent': 'fa'},
    );
    final child = await writeSessionFile(dir, id: '0198-child-h', metadata: {
      'agent': 'subagent',
      'id': 'hhhh88',
      'parent': '',
    });
    final path = await writeSessionFile(dir, id: parent.id, metadata: {
      'agent': 'fa',
    }, extraLines: [
      registryLine({child.id: child.path}),
    ]);
    final sessions = [path, child];

    final resolver = SubagentParentResolver();
    expect(await resolver.resolve(sessions), {child.id: parent.id});

    // Cached: identical result without the file growing.
    expect(await resolver.resolve(sessions), {child.id: parent.id});

    // A NEW registry (new parent mtime) flips the answer.
    final child2 = await writeSessionFile(dir, id: '0198-child-i', metadata: {
      'agent': 'subagent',
      'id': 'iiii99',
      'parent': '',
    });
    final updated = await writeSessionFile(dir, id: parent.id, metadata: {
      'agent': 'fa',
    }, extraLines: [
      registryLine({child.id: child.path, child2.id: child2.path}),
    ], mtime: DateTime.parse('2026-09-16T12:00:00.000'));
    // Update the in-listing metadata so the resolver sees the new mtime.
    final listing = [
      SessionMetadata(
        id: updated.id,
        createdAt: updated.createdAt,
        cwd: updated.cwd,
        path: updated.path,
        lastUpdatedAt: updated.lastUpdatedAt,
        metadata: updated.metadata,
      ),
      child,
      child2,
    ];
    expect(await resolver.resolve(listing), {
      child.id: parent.id,
      child2.id: parent.id,
    });
  });

  test('only subagent sessions with an EMPTY header parent are resolved; '
      'orphans without any registry parent stay out of the map', () async {
    final child = await writeSessionFile(dir, id: '0198-child-j', metadata: {
      'agent': 'subagent',
      'id': 'jjjj00',
      'parent': '',
    });
    // No parent file at all.
    expect(await SubagentParentResolver().resolve([child]), isEmpty);
  });

  test('a placeholder registry sessionId (never attached) resolves '
      'nothing', () async {
    final parent = await writeSessionFile(
      dir,
      id: '0198-parent-0015',
      metadata: {'agent': 'fa'},
    );
    final child = await writeSessionFile(dir, id: '0198-child-k', metadata: {
      'agent': 'subagent',
      'id': 'kkkk11',
      'parent': '',
    });
    await writeSessionFile(dir, id: parent.id, metadata: {
      'agent': 'fa',
    }, extraLines: [
      // `$parentSessionId/$id` with an empty prefix — the pre-attach
      // placeholder, not a real file path.
      registryLine({child.id: '/kkkk11'}),
    ]);

    expect(await SubagentParentResolver().resolve([parent, child]), isEmpty);
  });
}

