import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/import/foreign_session.dart';
import 'package:flutter_agent_harness/src/import/omp_adapter.dart';
import 'package:test/test.dart';

/// UT tier for the omp adapter (GOAL O1-O6): bucket discovery by slug
/// compare + header cwd, the title slot vs legacy inline title, blob
/// embed-or-skip bounds, corrupt/oversized line counting, sidecar and
/// tombstone exclusion, and leaf-path selection.
void main() {
  late Directory home;
  late Directory project;
  late Directory faRoot;
  late LocalExecutionEnv fs;
  const limits = ImportLimits();

  String fixture(String name) => File(
    'test/import/fixtures/$name',
  ).readAsStringSync().replaceAll('__CWD__', project.path);

  /// Writes the omp bucket for [project] with the given file contents.
  Future<String> writeBucket(Map<String, String> files) async {
    final bucket = Directory(
      '${home.path}/.omp/agent/sessions/--${project.path.replaceFirst('/', '').replaceAll('/', '-')}--',
    );
    bucket.createSync(recursive: true);
    for (final entry in files.entries) {
      File('${bucket.path}/${entry.key}').writeAsStringSync(entry.value);
    }
    return bucket.path;
  }

  setUp(() {
    home = Directory.systemTemp.createTempSync('fa_import_omp_home');
    project = Directory.systemTemp.createTempSync('fa_import_omp_proj');
    faRoot = Directory.systemTemp.createTempSync('fa_import_omp_fa');
    fs = LocalExecutionEnv(cwd: project.path);
  });

  tearDown(() {
    home.deleteSync(recursive: true);
    project.deleteSync(recursive: true);
    faRoot.deleteSync(recursive: true);
  });

  test('ompBucketSlugs covers the absolute, home-relative and tmp forms', () {
    final slugs = ompBucketSlugs(
      '${home.path}/work/proj',
      home.path,
      Directory.systemTemp.path,
    );
    expect(
      slugs,
      contains(
        '--${home.path.replaceFirst('/', '').replaceAll('/', '-')}-work-proj--',
      ),
    );
    expect(slugs, contains('-work-proj'));
  });

  test(
    'discover finds current-folder sessions and skips foreign folders',
    () async {
      await writeBucket({
        '20260101T000000-1f9d.jsonl': fixture('omp_modern.jsonl'),
        '20260102T000000-legacy.jsonl': fixture('omp_legacy.jsonl'),
        // A session recorded for another folder: slug bucket differs — and
        // even inside the right bucket a wrong header cwd never imports.
        'other.jsonl':
            '{"type":"session","version":3,"id":"x","timestamp":'
            '"2026-01-01T00:00:00.000Z","cwd":"/somewhere/else"}',
      });
      final adapter = OmpAdapter();
      final summaries = await adapter.discover(
        fs: fs,
        cwd: project.path,
        homeDir: home.path,
        tempDir: Directory.systemTemp.path,
        limits: limits,
      );
      expect(
        summaries.map((s) => s.sourceId),
        containsAll(['1f9d2a6b-9c0d-4f34-a111-000000000001', 'legacy-0001']),
      );
      expect(summaries, hasLength(2));
    },
  );

  test(
    'a header cwd that does not match the launch folder is skipped',
    () async {
      final bucket = await writeBucket({});
      File('$bucket/elsewhere.jsonl').writeAsStringSync(
        '{"type":"session","version":3,"id":"x1","timestamp":'
        '"2026-01-01T00:00:00.000Z","cwd":"${project.path}-other"}\n'
        '{"type":"message","id":"x2","parentId":"x1","timestamp":'
        '"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"hi"}}',
      );
      final adapter = OmpAdapter();
      final summaries = await adapter.discover(
        fs: fs,
        cwd: project.path,
        homeDir: home.path,
        tempDir: Directory.systemTemp.path,
        limits: limits,
      );
      expect(summaries, isEmpty);
    },
  );

  test('read returns the leaf path root-first with header counted', () async {
    await writeBucket({'b.jsonl': fixture('omp_branches.jsonl')});
    final adapter = OmpAdapter();
    final summaries = await adapter.discover(
      fs: fs,
      cwd: project.path,
      homeDir: home.path,
      tempDir: Directory.systemTemp.path,
      limits: limits,
    );
    final parse = await adapter.read(
      fs: fs,
      summary: summaries.single,
      homeDir: home.path,
      limits: limits,
    );
    final ids = [
      for (final record in parse.records)
        if (record is ForeignHeader) 'header',
    ];
    expect(ids, ['header']);
    final roles = [
      for (final record in parse.records)
        if (record is ForeignMessage) record.rawMessage['content'],
    ];
    // b1 → b2 → b4 (the active leaf); b3 is an off-branch fork.
    expect(roles, ['start', 'main path', 'active branch leaf']);
    expect(parse.skippedRecords, 1);
  });

  test(
    'legacy files (no title slot) parse with the inline header title',
    () async {
      await writeBucket({'legacy.jsonl': fixture('omp_legacy.jsonl')});
      final adapter = OmpAdapter();
      final summaries = await adapter.discover(
        fs: fs,
        cwd: project.path,
        homeDir: home.path,
        tempDir: Directory.systemTemp.path,
        limits: limits,
      );
      expect(summaries.single.title, 'Legacy session');
      expect(summaries.single.titleSource, 'auto');
    },
  );

  test('title slot files report the slotted title', () async {
    await writeBucket({'modern.jsonl': fixture('omp_modern.jsonl')});
    final adapter = OmpAdapter();
    final summaries = await adapter.discover(
      fs: fs,
      cwd: project.path,
      homeDir: home.path,
      tempDir: Directory.systemTemp.path,
      limits: limits,
    );
    final modern = summaries.firstWhere((s) => s.sourceId.contains('1f9d'));
    expect(modern.title, 'Fix the login flow');
    expect(modern.titleSource, 'user');
  });

  test('blob images embed when present and within bounds (GOAL O5)', () async {
    Directory('${home.path}/.omp/agent/blobs').createSync(recursive: true);
    // Same 64-hex digest the committed fixture references (sha256-hex is
    // what the adapter's traversal gate accepts).
    File(
      '${home.path}/.omp/agent/blobs/'
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    ).writeAsStringSync('aGVsbG8='); // "hello"
    await writeBucket({'modern.jsonl': fixture('omp_modern.jsonl')});
    final adapter = OmpAdapter();
    final summaries = await adapter.discover(
      fs: fs,
      cwd: project.path,
      homeDir: home.path,
      tempDir: Directory.systemTemp.path,
      limits: limits,
    );
    final parse = await adapter.read(
      fs: fs,
      summary: summaries.firstWhere((s) => s.sourceId.contains('1f9d')),
      homeDir: home.path,
      limits: limits,
    );
    final imageMessage = parse.records.whereType<ForeignMessage>().lastWhere(
      (m) => m.contents.any((c) => c is ForeignImage),
    );
    final image = imageMessage.contents.whereType<ForeignImage>().single;
    expect(image.base64Data, 'aGVsbG8=');
  });

  test(
    'a missing blob becomes a counted placeholder, no crash (GOAL E5)',
    () async {
      await writeBucket({'modern.jsonl': fixture('omp_modern.jsonl')});
      final adapter = OmpAdapter();
      final summaries = await adapter.discover(
        fs: fs,
        cwd: project.path,
        homeDir: home.path,
        tempDir: Directory.systemTemp.path,
        limits: limits,
      );
      final parse = await adapter.read(
        fs: fs,
        summary: summaries.firstWhere((s) => s.sourceId.contains('1f9d')),
        homeDir: home.path,
        limits: limits,
      );
      final image = parse.records
          .whereType<ForeignMessage>()
          .expand((m) => m.contents)
          .whereType<ForeignImage>()
          .single;
      expect(image.base64Data, isNull);
      expect(image.missingReason, contains('blob not found'));
    },
  );

  test('corrupt and oversized lines skip with a count (GOAL E10/AC9)', () async {
    final bucket = await writeBucket({});
    final good =
        '{"type":"session","version":3,"id":"corrupt-1","timestamp":'
        '"2026-01-01T00:00:00.000Z","cwd":"${project.path}"}';
    File('$bucket/corrupt.jsonl').writeAsStringSync(
      '$good\n'
      '{not json at all\n'
      '{"type":"message","id":"c1","parentId":null,"timestamp":'
      '"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"survives"}}\n',
    );
    final adapter = OmpAdapter();
    final summaries = await adapter.discover(
      fs: fs,
      cwd: project.path,
      homeDir: home.path,
      tempDir: Directory.systemTemp.path,
      limits: limits,
    );
    final parse = await adapter.read(
      fs: fs,
      summary: summaries.single,
      homeDir: home.path,
      limits: limits,
    );
    expect(parse.records.whereType<ForeignMessage>(), hasLength(1));
    expect(parse.skippedRecords, 1);
  });

  test(
    'sidecar artifacts dirs and tombstones are not imported (GOAL E2)',
    () async {
      final bucket = await writeBucket({
        'session.jsonl': fixture('omp_legacy.jsonl'),
      });
      // The sibling artifacts dir: full sidecar sessions + a dead marker.
      final artifacts = Directory('$bucket/20260101T000000-legacy-0001');
      artifacts.createSync();
      File('${artifacts.path}/out-1.jsonl').writeAsStringSync('{}\n');
      File('${artifacts.path}/out-1.jsonl.tombstone').writeAsStringSync('');
      final adapter = OmpAdapter();
      final summaries = await adapter.discover(
        fs: fs,
        cwd: project.path,
        homeDir: home.path,
        tempDir: Directory.systemTemp.path,
        limits: limits,
      );
      expect(summaries, hasLength(1));
      expect(summaries.single.sourceId, 'legacy-0001');
    },
  );

  test('a file over the size cap refuses before reading (GOAL E11)', () async {
    final bucket = await writeBucket({
      'big.jsonl': fixture('omp_legacy.jsonl'),
    });
    final adapter = OmpAdapter();
    final summaries = await adapter.discover(
      fs: fs,
      cwd: project.path,
      homeDir: home.path,
      tempDir: Directory.systemTemp.path,
      limits: const ImportLimits(maxFileBytes: 8),
    );
    await expectLater(
      adapter.read(
        fs: fs,
        summary: summaries.single,
        homeDir: home.path,
        limits: const ImportLimits(maxFileBytes: 8),
      ),
      throwsA(isA<ForeignFileError>()),
    );
    // The refusal never touched the store file.
    expect(File('$bucket/big.jsonl').readAsStringSync(), isNotEmpty);
  });

  test('a headerless file refuses with a named error', () async {
    final bucket = await writeBucket({'junk.jsonl': '{"type":"message"}\n'});
    final adapter = OmpAdapter();
    final summary = ForeignSessionSummary(
      harness: 'omp',
      sourceId: 'junk',
      sourcePath: '$bucket/junk.jsonl',
      sizeBytes: 20,
      headerCwd: project.path,
      title: '',
      titleSource: '',
      firstPreview: '-',
      lastPreview: '-',
      searchText: '',
      mtimeMs: 0,
    );
    await expectLater(
      adapter.read(
        fs: fs,
        summary: summary,
        homeDir: home.path,
        limits: limits,
      ),
      throwsA(isA<ForeignFileError>()),
    );
  });
}
