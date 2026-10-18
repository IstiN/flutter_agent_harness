import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/import/claude_adapter.dart';
import 'package:flutter_agent_harness/src/import/foreign_session.dart';
import 'package:flutter_agent_harness/src/import/import_runner.dart';
import 'package:flutter_agent_harness/src/import/omp_adapter.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:test/test.dart';

/// UT tier — the E11 reporting-parity invariant across backends (review
/// thread on `claude_adapter.dart`): an oversized session file must never
/// VANISH at discovery. Ranged backends read the bounded prefix and
/// discover it; backends without partial reads (the web shell shape,
/// `_NoRangeEnv` below) must still emit the summary — cwd unverified — so
/// `scanForeignLines`' read-time refusal produces the counted
/// `warning: skipped <id>: file too large` line for BOTH adapters.
void main() {
  late Directory home;
  late Directory project;
  late Directory faRoot;
  late LocalExecutionEnv ranged;

  String fixture(String name) => File(
    'test/import/fixtures/$name',
  ).readAsStringSync().replaceAll('__CWD__', project.path);

  Directory claudeBucket() => Directory(
    '${home.path}/.claude/projects/${claudeProjectSlug(project.path)}',
  )..createSync(recursive: true);

  Directory ompBucket() => Directory(
    '${home.path}/.omp/agent/sessions/--${project.path
        .replaceFirst('/', '')
        .replaceAll('/', '-')}--',
  )..createSync(recursive: true);

  setUp(() {
    home = Directory.systemTemp.createTempSync('fa_import_par_home');
    project = Directory.systemTemp.createTempSync('fa_import_par_proj');
    faRoot = Directory.systemTemp.createTempSync('fa_import_par_fa');
    ranged = LocalExecutionEnv(cwd: project.path);
  });

  tearDown(() {
    home.deleteSync(recursive: true);
    project.deleteSync(recursive: true);
    faRoot.deleteSync(recursive: true);
  });

  test('claude: over-cap file on a non-ranged backend is still discovered '
      'and refuses at read time', () async {
    File('${claudeBucket().path}/big.jsonl')
        .writeAsStringSync(fixture('claude_basic.jsonl'));
    final adapter = ClaudeAdapter();
    final summaries = await adapter.discover(
      fs: _NoRangeEnv(ranged),
      cwd: project.path,
      homeDir: home.path,
      tempDir: Directory.systemTemp.path,
      limits: const ImportLimits(maxFileBytes: 8),
    );
    // Discovered — not vanished into `no claude sessions found`.
    expect(summaries, hasLength(1));
    expect(summaries.single.sourceId, 'big');
    await expectLater(
      adapter.read(
        fs: _NoRangeEnv(ranged),
        summary: summaries.single,
        homeDir: home.path,
        limits: const ImportLimits(maxFileBytes: 8),
      ),
      throwsA(
        isA<ForeignFileError>().having(
          (e) => e.message,
          'message',
          contains('file too large'),
        ),
      ),
    );
  });

  test('claude: the non-ranged over-cap file warns with the counted '
      'warning through the runner', () async {
    File('${claudeBucket().path}/big.jsonl')
        .writeAsStringSync(fixture('claude_basic.jsonl'));
    final noRange = _NoRangeEnv(ranged);
    final lines = <String>[];
    final result = await runImport(
      adapter: ClaudeAdapter(),
      fs: noRange,
      repo: JsonlSessionRepo(fs: noRange, sessionsRoot: faRoot.path),
      cwd: project.path,
      selector: const ImportSelector.all(),
      limits: const ImportLimits(maxFileBytes: 8),
      homeDir: home.path,
      tempDir: Directory.systemTemp.path,
      onLine: lines.add,
    );
    expect(result.exitCode, 3, reason: 'nothing imported');
    expect(lines, hasLength(1));
    expect(lines.single, startsWith('warning: skipped big: '));
    expect(lines.single, contains('file too large'));
  });

  test('omp: over-cap file on a non-ranged backend is still discovered '
      'and warns through the runner (parity both ways)', () async {
    File('${ompBucket().path}/big.jsonl')
        .writeAsStringSync(fixture('omp_modern.jsonl'));
    final noRange = _NoRangeEnv(ranged);
    final adapter = OmpAdapter();
    final summaries = await adapter.discover(
      fs: noRange,
      cwd: project.path,
      homeDir: home.path,
      tempDir: Directory.systemTemp.path,
      limits: const ImportLimits(maxFileBytes: 8),
    );
    // Discovered with the file-stem id fallback (no header within the
    // cap on this backend class).
    expect(summaries, hasLength(1));
    expect(summaries.single.sourceId, 'big');
    final lines = <String>[];
    final result = await runImport(
      adapter: adapter,
      fs: noRange,
      repo: JsonlSessionRepo(fs: noRange, sessionsRoot: faRoot.path),
      cwd: project.path,
      selector: const ImportSelector.all(),
      limits: const ImportLimits(maxFileBytes: 8),
      homeDir: home.path,
      tempDir: Directory.systemTemp.path,
      onLine: lines.add,
    );
    expect(result.exitCode, 3, reason: 'nothing imported');
    expect(lines.single, startsWith('warning: skipped big: '));
    expect(lines.single, contains('file too large'));
  });
}

/// A capability-stripping wrapper over [LocalExecutionEnv]: implements
/// [FileSystem] only, so `is RangedReadFileSystem` is false — the
/// backend class the non-ranged discovery fallback serves (the
/// `_NoRenameEnv` decorator pattern from the session tests).
final class _NoRangeEnv implements FileSystem {
  _NoRangeEnv(this._base);

  final LocalExecutionEnv _base;

  @override
  String get cwd => _base.cwd;
  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _base.absolutePath(path);
  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _base.joinPath(parts);
  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _base.readTextFile(path);
  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _base.readBinaryFile(path);
  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _base.readTextLines(path, maxLines: maxLines);
  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _base.writeBinaryFile(path, content);
  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _base.writeFile(path, content);
  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _base.appendFile(path, content);
  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _base.fileInfo(path);
  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _base.listDir(path);
  @override
  Future<Result<bool, FileError>> exists(String path) => _base.exists(path);
  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _base.createDir(path, recursive: recursive);
  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _base.remove(path, recursive: recursive, force: force);
}
