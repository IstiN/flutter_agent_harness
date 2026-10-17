import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/import/foreign_session.dart';
import 'package:flutter_agent_harness/src/import/import_runner.dart';
import 'package:flutter_agent_harness/src/import/omp_adapter.dart';
import 'package:flutter_agent_harness/src/session/session_record.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:flutter_agent_harness/src/cli/trajectory_tui.dart';
import 'package:test/test.dart';

/// IT tier for the import runner (GOAL test matrix): real temp-dir stores,
/// `JsonlSessionRepo` round-trip, current-folder scoping, exit codes,
/// idempotency + kill-mid-import recovery, foreign-store read-only guard,
/// and the stdout byte-scan (AC1/AC2/AC9/AC10/AC11, E6-E11, E14, REG-5).
void main() {
  late Directory home;
  late Directory project;
  late Directory faRoot;
  late LocalExecutionEnv env;
  late JsonlSessionRepo repo;

  final lines = <String>[];

  String fixture(String name) => File(
    'test/import/fixtures/$name',
  ).readAsStringSync().replaceAll('__CWD__', project.path);

  // Local getters are invalid Dart — these are local functions (they
  // close over the `late` temp dirs that setUp assigns).
  String ompRoot() => '${home.path}/.omp/agent/sessions';

  String ompBucket() =>
      '${ompRoot()}/--${project.path.replaceFirst('/', '').replaceAll('/', '-')}--';

  Future<void> writeOmpStore(Map<String, String> files) async {
    Directory(ompBucket()).createSync(recursive: true);
    for (final entry in files.entries) {
      File('${ompBucket()}/${entry.key}').writeAsStringSync(entry.value);
    }
  }

  Future<ImportResult> run(
    ImportSelector selector, {
    ImportLimits limits = const ImportLimits(),
    String harness = 'omp',
  }) {
    lines.clear();
    return runImport(
      adapter: OmpAdapter(),
      fs: env,
      repo: repo,
      cwd: project.path,
      selector: selector,
      limits: limits,
      homeDir: home.path,
      tempDir: Directory.systemTemp.path,
      onLine: lines.add,
    );
  }

  setUp(() {
    home = Directory.systemTemp.createTempSync('fa_import_run_home');
    project = Directory.systemTemp.createTempSync('fa_import_run_proj');
    faRoot = Directory.systemTemp.createTempSync('fa_import_run_fa');
    env = LocalExecutionEnv(cwd: project.path);
    repo = JsonlSessionRepo(fs: env, sessionsRoot: faRoot.path);
  });

  tearDown(() {
    home.deleteSync(recursive: true);
    project.deleteSync(recursive: true);
    faRoot.deleteSync(recursive: true);
  });

  test('AC1: one session lands in the current folder bucket and renders',
      () async {
    await writeOmpStore({'s.jsonl': fixture('omp_modern.jsonl')});
    final result = await run(const ImportSelector.all());
    expect(result.exitCode, 0);
    expect(lines, hasLength(1));
    expect(lines.single, startsWith('imported 1f9d2a6b'));
    expect(lines.single, matches(RegExp(r'\(\d+ records, skipped \d+\)(\s*\[[^\]]*\])?$')));

    final sessions = await repo.list(cwd: project.path);
    expect(sessions, hasLength(1));
    final bucketDir = Directory(
      '${faRoot.path}/${encodeSessionCwd(project.path)}',
    );
    expect(bucketDir.existsSync(), isTrue);
    expect(bucketDir.listSync().whereType<File>(), hasLength(1));

    // The imported name rides the foreign title, newline-free (AC4).
    final name = await repo.sessionNameQuick(sessions.single);
    expect(name, 'Fix the login flow (renamed)');

    // Existing surfaces read it: trajectory projection renders the branch.
    final session = await repo.open(sessions.single);
    final snapshot = trajectorySnapshotOf(await session.getBranch());
    expect(trajectoryLines(snapshot, width: 80), isNotEmpty);

    // The dedupe marker survives reload (F12/AC10).
    final marker = sessions.single.metadata?['importedFrom'];
    expect(marker, isA<Map>());
    expect((marker as Map)['sourceId'], '1f9d2a6b-9c0d-4f34-a111-000000000001');
    expect(marker['harness'], 'omp');
    expect(marker['recordCount'], greaterThan(0));
  });

  test('AC2 + E6: --all imports every session; reruns skip idempotently',
      () async {
    await writeOmpStore({
      'a.jsonl': fixture('omp_modern.jsonl'),
      'b.jsonl': fixture('omp_legacy.jsonl'),
    });
    final first = await run(const ImportSelector.all());
    expect(first.exitCode, 0);
    expect(lines.where((l) => l.startsWith('imported ')), hasLength(2));

    final second = await run(const ImportSelector.all());
    expect(second.exitCode, 0, reason: 'already-imported is not an error');
    expect(lines.where((l) => l.startsWith('skipped ')), hasLength(2));
    expect(
      await repo.list(cwd: project.path),
      hasLength(2),
      reason: 're-import writes nothing new',
    );
  });

  test('E7: an absent store exits 2 naming the expected path', () async {
    final result = await run(const ImportSelector.all());
    expect(result.exitCode, 2);
    expect(lines.single, contains(ompRoot()));
  });

  test('E8: a store without current-folder sessions exits 3', () async {
    Directory(ompRoot()).createSync(recursive: true);
    final result = await run(const ImportSelector.all());
    expect(result.exitCode, 3);
  });

  test('E9: an unresolved id exits 3 and imports nothing', () async {
    await writeOmpStore({
      'p1.jsonl': fixture('omp_modern.jsonl'),
      'p2.jsonl': fixture('omp_legacy.jsonl'),
    });
    final result = await run(const ImportSelector.one('zzz'));
    expect(result.exitCode, 3);
    expect(lines.single, contains('no session matches'));
    expect(await repo.list(cwd: project.path), isEmpty);
  });

  test('E9b: an ambiguous id lists the matches and imports nothing',
      () async {
    final modern = fixture('omp_modern.jsonl');
    await writeOmpStore({
      'p1.jsonl': modern,
      // Same header id in two files: the selector cannot disambiguate.
      'p2.jsonl': modern,
    });
    final all = await run(const ImportSelector.all());
    expect(all.exitCode, 0);
    // The duplicate source id dedupes: one FA session, one skip line.
    expect(lines.where((l) => l.startsWith('imported ')), hasLength(1));
    expect(lines.where((l) => l.startsWith('skipped ')), hasLength(1));
    lines.clear();
    final ambiguous = await run(
      const ImportSelector.one('1f9d2a6b-9c0d-4f34-a111-000000000001'),
    );
    expect(ambiguous.exitCode, 3);
    expect(lines.single, contains('ambiguous'));
    expect(await repo.list(cwd: project.path), hasLength(1));
  });

  test('E10: a corrupt line mid-file skips with a count, rest imports',
      () async {
    final linesText = fixture('omp_legacy.jsonl').split('\n');
    linesText.insert(2, '{this is not json');
    Directory(ompBucket()).createSync(recursive: true);
    File('${ompBucket()}/corrupt.jsonl').writeAsStringSync(linesText.join('\n'));
    final result = await run(const ImportSelector.all());
    expect(result.exitCode, 0);
    expect(lines.single, matches(RegExp(r'skipped [1-9]+\)')));
  });

  test('E14: a kill-mid-import file is replaced on retry (AC10)', () async {
    await writeOmpStore({'s.jsonl': fixture('omp_modern.jsonl')});
    expect((await run(const ImportSelector.all())).exitCode, 0);
    final before = await repo.list(cwd: project.path);
    expect(before, hasLength(1));

    // Simulate the kill: strip the completion entry (the FINAL record).
    final file = File(before.single.path);
    final text = file.readAsStringSync();
    final withoutComplete = text
        .split('\n')
        .where(
          (line) => !line.contains('import.omp.complete'),
        )
        .join('\n');
    file.writeAsStringSync(withoutComplete);

    final retry = await run(const ImportSelector.all());
    expect(retry.exitCode, 0);
    expect(lines.single, startsWith('imported '), reason: 'replaced, not skipped');
    final after = await repo.list(cwd: project.path);
    expect(after, hasLength(1));
    final session = await repo.open(after.single);
    final records = await session.getEntries();
    expect(
      records.whereType<CustomRecord>().any(
        (r) => r.customType == 'import.omp.complete',
      ),
      isTrue,
    );
  });

  test('AC9: oversized files refuse with an explicit reason and no import',
      () async {
    await writeOmpStore({'big.jsonl': fixture('omp_modern.jsonl')});
    final result = await run(
      const ImportSelector.all(),
      limits: const ImportLimits(maxFileBytes: 16),
    );
    expect(result.exitCode, 3, reason: 'nothing imported');
    expect(lines.single, startsWith('warning: skipped'));
    expect(lines.single, contains('file too large'));
    expect(await repo.list(cwd: project.path), isEmpty);
  });

  test('REG-5 + AC11: the foreign store stays byte-identical and stdout '
      'carries ids/counts only', () async {
    await writeOmpStore({
      'a.jsonl': fixture('omp_modern.jsonl'),
      'b.jsonl': fixture('omp_legacy.jsonl'),
    });
    final foreignBefore = <String, String>{
      for (final file in Directory(ompBucket()).listSync().whereType<File>())
        file.path: file.readAsStringSync(),
    };
    final homeBefore = _treeSnapshot(home);

    final result = await run(const ImportSelector.all());
    expect(result.exitCode, 0);

    // REG-5: every foreign byte identical.
    for (final entry in foreignBefore.entries) {
      expect(File(entry.key).readAsStringSync(), entry.value);
    }
    // AC11: no writes anywhere under the foreign home except... nothing:
    // the tree is byte-for-byte the same set of files with same content.
    expect(_treeSnapshot(home), homeBefore);
    // AC11: output lines expose ids and counts, never message content.
    final output = lines.join('\n');
    expect(output, isNot(contains('please fix the login flow')));
    expect(output, isNot(contains('legacy answer')));
    expect(output, isNot(contains('hello from legacy')));
  });
}

/// path → (size, mtimeMs) for every file under [dir].
Map<String, (int, int)> _treeSnapshot(Directory dir) => {
  for (final entity in dir.listSync(recursive: true).whereType<File>())
    entity.path: (entity.lengthSync(), entity.statSync().modified.millisecondsSinceEpoch),
};
