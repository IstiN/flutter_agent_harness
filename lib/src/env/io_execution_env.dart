/// `dart:io`-backed [ExecutionEnv] for VM, desktop, and mobile targets.
///
/// **This library is not web-safe.** It is the only `dart:io` subtree of the
/// package and is exported only through `lib/io.dart`; the core library
/// (`lib/flutter_agent_harness.dart`) never imports it, so web compilation
/// of the core stays clean.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../cancel_token.dart';
import '../cube/config/fs_policy.dart';
import 'bash_guard_io.dart';
import 'execution_env.dart';
import 'free_space_io.dart';
import 'job_log_ceiling.dart';
import 'job_log_redaction.dart';
// Same dart:io subgraph — the survivor-scan `ps` probes (issue #2201).
import 'process_probe_io.dart';

FileError _toFileError(Object error, String path) {
  if (error is FileError) return error;
  if (error is PathNotFoundException) {
    return FileError(
      FileErrorCode.notFound,
      error.message,
      path: path,
      cause: error,
    );
  }
  if (error is FileSystemException) {
    return _fromFileSystemException(error, path);
  }
  return FileError(
    FileErrorCode.unknown,
    error.toString(),
    path: path,
    cause: error,
  );
}

/// The raw OS reason a [FileSystemException] carries (issue #2248 AC1):
/// `error.message` alone is the generic engine text ("Cannot open file")
/// — EMFILE vs EACCES vs a sandbox/container revocation are
/// indistinguishable from it, which is exactly why the 2026-11-17
/// wedge's root cause could not be diagnosed from fa.log. The errno +
/// OS message ride every [FileError] this env produces.
String _osErrorDetail(OSError? osError) =>
    osError == null ? '' : ' (errno ${osError.errorCode}: ${osError.message})';

FileError _fromFileSystemException(FileSystemException error, String path) {
  final osError = error.osError;
  final detail = _osErrorDetail(osError);
  if (osError != null) {
    // EPERM / EACCES on POSIX; ERROR_ACCESS_DENIED (5) on Windows.
    if (osError.errorCode == 13 ||
        osError.errorCode == 1 ||
        osError.errorCode == 5) {
      return FileError(
        FileErrorCode.permissionDenied,
        '${error.message}$detail',
        path: path,
        cause: error,
      );
    }
    // ENOTDIR on POSIX.
    if (osError.errorCode == 20) {
      return FileError(
        FileErrorCode.notDirectory,
        '${error.message}$detail',
        path: path,
        cause: error,
      );
    }
  }
  return FileError(
    FileErrorCode.unknown,
    '${error.message}$detail',
    path: path,
    cause: error,
  );
}

/// Local-disk [FileSystem] backed by `dart:io`.
///
/// Relative paths resolve against [cwd] (default: the process working
/// directory). All operations uphold the [FileSystem] never-throw invariant.
final class LocalFileSystem
    implements
        FileSystem,
        RangedReadFileSystem,
        RenamableFileSystem,
        ExclusiveCreateFileSystem {
  /// Creates a [LocalFileSystem] rooted at [cwd].
  LocalFileSystem({String? cwd}) : cwd = cwd ?? Directory.current.path;

  @override
  final String cwd;

  String _resolve(String path) {
    if (path.startsWith('/') || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path)) {
      return path;
    }
    return '$cwd/$path';
  }

  @override
  Future<Result<String, FileError>> absolutePath(String path) async {
    return Ok(_resolve(path));
  }

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) async {
    return Ok(parts.join('/'));
  }

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    final resolved = _resolve(path);
    try {
      final stat = await FileStat.stat(resolved);
      if (stat.type == FileSystemEntityType.directory) {
        return Err(
          FileError(
            FileErrorCode.isDirectory,
            'Is a directory',
            path: resolved,
          ),
        );
      }
      return Ok(await File(resolved).readAsString());
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) async {
    final resolved = _resolve(path);
    try {
      final stat = await FileStat.stat(resolved);
      if (stat.type == FileSystemEntityType.directory) {
        return Err(
          FileError(
            FileErrorCode.isDirectory,
            'Is a directory',
            path: resolved,
          ),
        );
      }
      return Ok(await File(resolved).readAsBytes());
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) async {
    final resolved = _resolve(path);
    if (end <= start) return Ok(Uint8List(0));
    RandomAccessFile? handle;
    try {
      handle = await File(resolved).open();
      final length = await handle.length();
      final from = start.clamp(0, length);
      final to = end.clamp(from, length);
      if (to <= from) return Ok(Uint8List(0));
      await handle.setPosition(from);
      return Ok(await handle.read(to - from));
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    } finally {
      await handle?.close();
    }
  }

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) async {
    if (maxLines != null && maxLines <= 0) return const Ok([]);
    final resolved = _resolve(path);
    try {
      final lines = <String>[];
      final stream = File(
        resolved,
      ).openRead().transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in stream) {
        lines.add(line);
        if (maxLines != null && lines.length >= maxLines) break;
      }
      return Ok(lines);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) async {
    final resolved = _resolve(path);
    try {
      await Directory(File(resolved).parent.path).create(recursive: true);
      await File(resolved).writeAsString(content);
      return const Ok(null);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) async {
    final resolved = _resolve(path);
    try {
      await Directory(File(resolved).parent.path).create(recursive: true);
      await File(resolved).writeAsBytes(content);
      return const Ok(null);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<void, FileError>> appendFile(
    String path,
    String content,
  ) async {
    final resolved = _resolve(path);
    try {
      await Directory(File(resolved).parent.path).create(recursive: true);
      await File(resolved).writeAsString(content, mode: FileMode.append);
      return const Ok(null);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) async {
    final resolved = _resolve(path);
    try {
      final stat = await FileStat.stat(resolved);
      // A missing path reports FileSystemEntityType.notFound — surface a
      // real not-found instead of the misleading "Unsupported file type"
      // (which only fits exotic nodes: sockets, fifos, devices).
      if (stat.type == FileSystemEntityType.notFound) {
        return Err(
          FileError(
            FileErrorCode.notFound,
            'No such file or directory',
            path: resolved,
          ),
        );
      }
      final kind = switch (stat.type) {
        FileSystemEntityType.file => FileKind.file,
        FileSystemEntityType.directory => FileKind.directory,
        FileSystemEntityType.link => FileKind.symlink,
        _ => null,
      };
      if (kind == null) {
        return Err(
          FileError(
            FileErrorCode.invalid,
            'Unsupported file type',
            path: resolved,
          ),
        );
      }
      return Ok(
        FileInfo(
          // Windows paths carry backslash segments (and dart:io mixes
          // them with the forward slashes we joined) — split on both or
          // `name` comes back as a whole multi-segment path (observed on
          // Windows: listDir names like `apps\2048` broke the apps
          // catalog and every other basename consumer). POSIX is the
          // opposite: backslash is a LEGAL name byte (`weird\name.txt`
          // is one file), so only '/' separates there.
          name: Platform.isWindows
              ? resolved.split(RegExp(r'[/\\]')).last
              : resolved.split('/').last,
          path: resolved,
          kind: kind,
          size: stat.size,
          mtimeMs: stat.modified.millisecondsSinceEpoch,
        ),
      );
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async {
    final resolved = _resolve(path);
    try {
      final infos = <FileInfo>[];
      await for (final entity in Directory(resolved).list(followLinks: false)) {
        final info = await fileInfo(entity.path);
        if (info.isOk) infos.add(info.valueOrNull!);
      }
      infos.sort((a, b) => a.name.compareTo(b.name));
      return Ok(infos);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<bool, FileError>> exists(String path) async {
    final resolved = _resolve(path);
    try {
      final type = await FileSystemEntity.type(resolved, followLinks: false);
      return Ok(type != FileSystemEntityType.notFound);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) async {
    final resolved = _resolve(path);
    try {
      await Directory(resolved).create(recursive: recursive);
      return const Ok(null);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<void, FileError>> createFileExclusive(String path) async {
    final resolved = _resolve(path);
    try {
      // O_EXCL: the call fails when anything already occupies the path —
      // the primitive cross-process locks need (issue #2266; a plain
      // Directory.create is a no-op over an existing dir, never a lock).
      await File(resolved).create(recursive: false, exclusive: true);
      return const Ok(null);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) async {
    final resolved = _resolve(path);
    try {
      final type = await FileSystemEntity.type(resolved, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        if (force) return const Ok(null);
        return Err(
          FileError(
            FileErrorCode.notFound,
            'No such file or directory',
            path: resolved,
          ),
        );
      }
      if (type == FileSystemEntityType.directory) {
        await Directory(resolved).delete(recursive: recursive);
      } else {
        await File(resolved).delete();
      }
      return const Ok(null);
    } on Object catch (error) {
      if (error is FileSystemException && !recursive) {
        return Err(
          FileError(
            FileErrorCode.invalid,
            error.message,
            path: resolved,
            cause: error,
          ),
        );
      }
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<void, FileError>> renamePath(String from, String to) async {
    final resolvedFrom = _resolve(from);
    final resolvedTo = _resolve(to);
    try {
      await File(resolvedFrom).rename(resolvedTo);
      return const Ok(null);
    } on Object catch (error) {
      return Err(_toFileError(error, resolvedTo));
    }
  }
}

/// Real-filesystem [CubeFsProbe]: `FileSystemEntity.typeSync` (nofollow)
/// spots link nodes, `Link.targetSync` reads them. A link node whose target
/// cannot be read (link swapped mid-flight, unreadable reparse point)
/// reports `(isLink: true, target: null)` — fail-closed deny. Errors that
/// dart:io maps to `notFound` (missing path, unreadable parent) read as
/// "not a link" and fall to the lexical floor: the same-uid opener is
/// equally blind there, so no privilege is leaked. Never throws.
final class LocalCubeFsProbe implements CubeFsProbe {
  const LocalCubeFsProbe();

  @override
  CubeLinkTarget linkTarget(String path) {
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.link) {
        return (isLink: false, target: null);
      }
      return (isLink: true, target: Link(path).targetSync());
    } on Object {
      // Link node we could stat but cannot read: fail closed rather than
      // guess.
      return (isLink: true, target: null);
    }
  }
}

/// Minimal local shell backed by `dart:io` `Process`.
///
/// Executes commands via `sh -c` (POSIX) or `cmd /c` (Windows). Streaming
/// callbacks receive output chunks as they arrive; timeout and cancellation
/// kill the process. This is the v1 shell — pi's richer bash-discovery logic
/// is deferred until a tool actually needs it.
final class LocalShell implements Shell, BackgroundShell {
  /// Creates a [LocalShell].
  const LocalShell({this.diskFreeProbe = diskFreeBytes});

  /// Low-disk probe for the job-log guard (issue #919); takes the log's
  /// directory, injectable for tests. Null disables the guard.
  final Future<int?> Function(String directory)? diskFreeProbe;

  @override
  bool get backgroundJobsSupported => true;

  /// Test seam: pin the own-process-group decision before the first job of
  /// a test starts. Null = probe the host once.
  static bool? ownProcessGroupOverride;
  static bool? _ownGroupCached;

  /// Whether children can start as their own session and process-group
  /// leader (`setsid sh -c …`, posix only): background jobs then stop with
  /// one group kill and the boot sweep can recognize a job's leftover group
  /// after a crash (issue #517), and a timed-out/cancelled FOREGROUND exec
  /// reaps its whole tree the same way instead of stranding a surviving
  /// grandchild on the output pipe (gh-1053). setsid execs sh in place —
  /// no fork — so the tracked pid IS the group id.
  static bool get ownProcessGroupAvailable =>
      ownProcessGroupOverride ?? (_ownGroupCached ??= _probeOwnProcessGroup());

  /// Our own process group id (issue #2201): the orphan-window scan on
  /// non-ownGroup hosts (macOS) matches survivors against it. The harness
  /// process never changes groups, so this is read once; null when the
  /// platform cannot report it (the scan then finds nothing — honest).
  static int? get ourPgid =>
      ourPgidOverride ?? (_ourPgidCached ??= _probeOurPgid());
  static int? _ourPgidCached;

  /// Test seam (issue #2276): a non-null harness pgid for the non-ownGroup
  /// survivor classifier, avoiding a real `ps` probe in call-site tests.
  static int? ourPgidOverride;

  static int? _probeOurPgid() {
    if (Platform.isWindows) return null;
    try {
      final out = Process.runSync('ps', ['-o', 'pgid=', '-p', '$pid']);
      if (out.exitCode != 0) return null;
      return int.tryParse(out.stdout.toString().trim());
    } on Object {
      return null;
    }
  }

  static bool _probeOwnProcessGroup() {
    if (Platform.isWindows) return false;
    try {
      return Process.runSync('sh', [
            '-c',
            'command -v setsid >/dev/null 2>&1',
          ]).exitCode ==
          0;
    } on Object {
      return false;
    }
  }

  /// Grace between the TERM and the KILL round of a tree kill: enough for
  /// well-behaved children to exit, short enough to keep `bash_job stop`
  /// snappy.
  static const _killGrace = Duration(milliseconds: 400);

  /// Cap on the stdout/stderr pipe-drain wait after a foreground tree kill
  /// (gh-1053): a descendant that survived the kill (or one the walk could
  /// not see) can hold the pipe write end indefinitely — the exec future
  /// must still return, with the partial capture. Total foreground bound:
  /// timeout + [_killGrace] + this grace.
  static const _drainGrace = Duration(seconds: 3);

  /// Test seam (issue #2276): replaces the walk-kill rounds' `ps`
  /// descendant walk. Receives the CURRENT round's root set — walk #1
  /// roots at `{pid}`. Null = the real walk.
  static Future<Set<int>> Function(Set<int> roots)? descendantsOfOverride;

  /// Test seam (issue #2276): replaces the walk rounds' per-pid signal
  /// ([Process.killPid]). Null = the real signal.
  static void Function(int pid, ProcessSignal signal)? signalPidOverride;

  /// Test seam (issue #2276): replaces the post-exit survivor table. Null =
  /// the real `ps` probe; a null RETURN still means an unavailable table.
  static Future<List<ProcessDetailRow>?> Function()?
  processDetailTableSnapshotOverride;

  /// Whether an exit should run the #2201 survivor scan (issue #2276): a
  /// normal exit always — nothing was signaled, so anything left behind is
  /// the caller's detached work to re-track. A stopped/timed-out exit only
  /// on hosts without group leadership: there the tree kill is a
  /// best-effort `ps` walk whose reparented TERM-trapping grandchildren
  /// can survive it, and adoption must re-track them; on ownGroup hosts
  /// the group kill owns every descendant (gh-1053) and the scan would
  /// find nothing.
  static bool shouldScanSurvivors({
    required bool stopped,
    required bool ownGroup,
  }) => !stopped || !ownGroup;

  /// Stops a foreground process tree (gh-1053): [killTree] reaps the whole
  /// tree — one group signal when the child leads its own group, the live
  /// `ps` walk otherwise, `taskkill /T` on Windows — then a direct kill
  /// backstops whatever the tree round missed. Mirrors `_LocalShellJob
  /// .stop()`. Best-effort: never throws.
  static Future<void> _stopTree(
    Process process, {
    required bool ownGroup,
  }) async {
    await LocalShell.killTree(process.pid, ownGroup: ownGroup);
    process.kill();
  }

  /// Terminates [pid]'s whole process tree (issue #517): the process group
  /// when the job is its own group leader (one signal — also covers
  /// children forked while the kill runs), otherwise a live `ps` descendant
  /// walk whose KILL round re-roots at the TERM round's victim set so a
  /// reaped leader cannot hide reparented survivors (issue #2276); Windows
  /// delegates to `taskkill /T`. The walk path freezes the leader for its
  /// first snapshot, then sends TERM, resumes it, allows a short grace, and
  /// sends KILL. Best-effort: never throws.
  static Future<void> killTree(int pid, {required bool ownGroup}) async {
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
        return;
      }
      if (ownGroup) {
        Process.killPid(-pid, ProcessSignal.sigterm);
        await Future<void>.delayed(_killGrace);
        Process.killPid(-pid, ProcessSignal.sigkill);
        return;
      }
      // No group leadership on this host (no setsid): walk the live tree.
      // Process.start can return before sh has parsed the command and forked
      // its children. Freeze the leader across walk #1 so an immediate stop
      // cannot snapshot the leader alone, TERM it, and lose a child forked
      // after that snapshot when the whole retained root set is reaped.
      await _signalAll({pid}, ProcessSignal.sigstop);
      var resumeLeader = true;
      try {
        final walk = descendantsOfOverride ?? _descendantsOf;
        var victims = await walk({pid});
        if (victims.isEmpty) return;
        await _signalAll(victims, ProcessSignal.sigterm);
        await _signalAll(victims, ProcessSignal.sigcont);
        resumeLeader = false;
        await Future<void>.delayed(_killGrace);
        // The KILL round re-roots at the TERM round's own victim set, never
        // at the bare pid (issue #2276): the leader is often already reaped
        // by then — ps drops its row, a root-at-pid walk returns {} — and
        // TERM-trapping grandchildren survive the stop while it answers
        // "Stopped". The kept set reaches fully-orphaned survivors (their
        // rows reparented to init); the re-walk widens for children forked
        // during the grace. A walk-#1 pid recycled to a stranger within the
        // grace would be signaled — the same scan-then-signal race the
        // rounds already accept.
        victims = await walk(victims);
        await _signalAll(victims, ProcessSignal.sigkill);
      } finally {
        // A failed/empty ps walk must not leave the job stopped forever.
        if (resumeLeader) await _signalAll({pid}, ProcessSignal.sigcont);
      }
    } on Object {
      // Best-effort: stop() still backstops the direct child.
    }
  }

  /// [roots] still observable in the `ps` table, plus every live
  /// descendant of those, via one `ps` ppid scan. Roots already reaped are
  /// dropped; a walk-#1 pid recycled to a stranger within the kill grace
  /// is indistinguishable from a survivor — the same scan-then-signal
  /// race the kill rounds already accept (issue #2276 keeps the walk-#1
  /// set precisely to reach survivors whose whole ancestor chain was
  /// reaped, their rows reparented to init). Empty when no root is
  /// observable.
  static Future<Set<int>> _descendantsOf(Set<int> roots) async {
    final ps = await Process.run('ps', ['-ax', '-o', 'pid=,ppid=']);
    final parentOf = <int, int>{};
    for (final line in (ps.stdout as String).split('\n')) {
      final cols = line.trim().split(RegExp(r'\s+'));
      if (cols.length < 2) continue;
      final pid = int.tryParse(cols[0]);
      final ppid = int.tryParse(cols[1]);
      if (pid != null && ppid != null) parentOf[pid] = ppid;
    }
    final live = roots.where(parentOf.containsKey).toSet();
    if (live.isEmpty) return const {};
    final children = <int, List<int>>{};
    parentOf.forEach((pid, ppid) {
      children.putIfAbsent(ppid, () => <int>[]).add(pid);
    });
    final out = <int>{...live};
    final queue = <int>[...live];
    while (queue.isNotEmpty) {
      for (final child in children[queue.removeAt(0)] ?? const <int>[]) {
        if (out.add(child)) queue.add(child);
      }
    }
    return out;
  }

  static Future<void> _signalAll(Set<int> pids, ProcessSignal signal) async {
    final killPid = signalPidOverride ?? Process.killPid;
    for (final pid in pids) {
      try {
        killPid(pid, signal);
      } on Object {
        // Vanished between the scan and the signal.
      }
    }
  }

  /// The child environment: the host's, with the caller's `options.env`
  /// merged on top (its values override, per the [ShellExecOptions.env]
  /// contract — injected vars such as secrets or `FAH_SESSION_*` must not
  /// strip the inherited environment). PATH always gains the common tool
  /// directories (`/opt/homebrew/bin`, `/usr/local/bin` when they exist) —
  /// GUI-launched apps (the packaged macOS app) inherit a minimal PATH that
  /// would otherwise hide user-installed tools (Homebrew python/node).
  ///
  /// gh-1763: with a provisioned [guard], the caller-supplied PATH gains
  /// the bash-guard shim dir at its head and the protected pid chain rides
  /// [bashGuardPidsEnv] (a caller-supplied value wins — tests inject a
  /// custom set that way).
  static Map<String, String> _environment(
    ShellExecOptions? options, {
    BashGuardProvision? guard,
  }) {
    final given = options?.env;
    final base = <String, String>{...Platform.environment, ...?given};
    // Non-interactive tool runs: a git clone against an auth-requiring
    // remote used to open /dev/tty ("Username for 'https://…':") and block
    // the whole agent run on the TUI-owned terminal — the session looked
    // stuck at the input zone with dead keyboard input. Defaults (a
    // caller's explicit env still wins):
    // GIT_TERMINAL_PROMPT=0 makes git fail fast with "terminal prompts
    // disabled", GIT_ASKPASS=echo keeps GUI credential helpers out of an
    // unattended child (echo returns an empty credential — auth fails
    // immediately instead of prompting).
    _applyIfUnset(base, const {
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_ASKPASS': 'echo',
    }, given);
    var current = base['PATH'] ?? '';
    if (current.isEmpty) {
      // An explicit env without a PATH (or a minimal GUI-app PATH): keep
      // the shell itself resolvable, then widen for user tools.
      current = Platform.environment['PATH'] ?? '';
    }
    if (current.isEmpty) current = '/usr/bin:/bin:/usr/sbin:/sbin';
    final parts = current.split(':');
    for (final dir in const ['/opt/homebrew/bin', '/usr/local/bin']) {
      if (!parts.contains(dir) && Directory(dir).existsSync()) parts.add(dir);
    }
    base['PATH'] = parts.join(':');
    if (guard != null) {
      final overlay = guard.environmentOverlay();
      final shimDir = overlay.remove(bashGuardShimDirEnv);
      // A caller-supplied pid set wins (tests inject a custom set; hosts
      // never ship one).
      _applyIfUnset(base, overlay, given);
      if (shimDir != null) {
        base['PATH'] = '$shimDir:${base['PATH'] ?? ''}';
      }
    }
    return base;
  }

  /// Copies [overlay] into [base] for every key the caller did not set
  /// explicitly (a caller's explicit env always wins).
  static void _applyIfUnset(
    Map<String, String> base,
    Map<String, String> overlay,
    Map<String, String>? given,
  ) {
    for (final entry in overlay.entries) {
      if (given == null || !given.containsKey(entry.key)) {
        base[entry.key] = entry.value;
      }
    }
  }

  /// The bash-guard provision (gh-1763), built once per process: the
  /// protected pid chain (harness + ancestors + process group) and the
  /// `pkill`/`killall` PATH shims. Null on Windows or when provisioning
  /// fails — the legacy delivery stays.
  static Future<BashGuardProvision?>? _bashGuardMemo;
  static Future<BashGuardProvision?> _bashGuard() =>
      _bashGuardMemo ??= provisionBashGuard();

  /// Writes the bash tool script to a per-exec private temp dir (gh-1763
  /// AC1): the wrapper argv then carries only `. "$1"` plus the path — the
  /// script body (with any `pkill -f <pattern>`) never lands in
  /// `/proc/<pid>/cmdline`, so a broad kill inside the script cannot match
  /// its own shell. The caller deletes the dir once the process exits.
  /// Null on any failure → the legacy `sh -c <command>` delivery.
  static Future<Directory?> _writeGuardedScript(String command) async {
    Directory dir;
    try {
      dir = await Directory.systemTemp.createTemp('fa_sh_cmd_');
    } on Object {
      return null;
    }
    try {
      await File(
        '${dir.path}/cmd.sh',
      ).writeAsString('${bashGuardPrelude()}\n$command\n');
      return dir;
    } on Object {
      try {
        dir.deleteSync(recursive: true);
      } on Object {
        // Best-effort cleanup of the failed write.
      }
      return null;
    }
  }

  static Future<(Result<Process, ExecutionError>, Directory?)> _start(
    String command,
    ShellExecOptions? options, {
    bool ownSession = false,
  }) async {
    // gh-1763 AC1 (POSIX only; Windows `cmd /c` keeps the verbatim
    // command — it has no pkill to self-match): deliver the script from a
    // per-exec temp file so the wrapper argv never carries the script
    // body. `$0` stays `sh`; the prelude's `set --` restores `sh -c`
    // positional-parameter parity.
    //
    // ownSession (issue #517): `setsid` makes the job its own session and
    // process-group leader — pgid == pid — so stop() can signal the whole
    // tree and the boot sweep can recognize leftover groups. setsid execs
    // sh in place, so the spawned pid is still the tracked one.
    final guard = await _bashGuard();
    final scriptDir = Platform.isWindows
        ? null
        : await _writeGuardedScript(command);
    final (executable, args) = _childCommand(command, scriptDir, ownSession);
    try {
      final process = await Process.start(
        executable,
        args,
        workingDirectory: options?.cwd,
        environment: _environment(options, guard: guard),
      );
      _deleteScriptWhenExited(scriptDir, process);
      return (Ok<Process, ExecutionError>(process), scriptDir);
    } on Object catch (error) {
      _deleteScriptNow(scriptDir);
      return (
        Err<Process, ExecutionError>(
          ExecutionError(
            ExecutionErrorCode.spawnError,
            error.toString(),
            cause: error,
          ),
        ),
        null,
      );
    }
  }

  /// The child argv for one tool run. gh-1763 AC1 (POSIX only; Windows
  /// `cmd /c` keeps the verbatim command — it has no pkill to
  /// self-match): the script body rides a per-exec temp file so the
  /// wrapper argv never carries it. `$0` stays `sh`; the prelude's
  /// `set --` restores `sh -c` positional-parameter parity.
  ///
  /// ownSession (issue #517): `setsid` makes the job its own session and
  /// process-group leader — pgid == pid — so stop() can signal the whole
  /// tree and the boot sweep can recognize leftover groups. setsid execs
  /// sh in place, so the spawned pid is still the tracked one.
  static (String, List<String>) _childCommand(
    String command,
    Directory? scriptDir,
    bool ownSession,
  ) {
    final effectiveCommand = scriptDir == null ? command : '. "\$1"';
    final executable = Platform.isWindows
        ? 'cmd'
        : ownSession
        ? 'setsid'
        : 'sh';
    final List<String> args;
    if (Platform.isWindows) {
      args = ['/c', command];
    } else if (scriptDir != null) {
      final scriptPath = '${scriptDir.path}/cmd.sh';
      args = ownSession
          ? ['sh', '-c', effectiveCommand, 'sh', scriptPath]
          : ['-c', effectiveCommand, 'sh', scriptPath];
    } else {
      args = ownSession ? ['sh', '-c', command] : ['-c', command];
    }
    return (executable, args);
  }

  /// The script file must outlive the shell that reads it — remove it
  /// once the child exits (nothing inside can reference the path: `$0`
  /// is `sh` and the path leaks nowhere else).
  static void _deleteScriptWhenExited(Directory? scriptDir, Process process) {
    if (scriptDir == null) return;
    unawaited(process.exitCode.then((_) => _deleteScriptNow(scriptDir)));
  }

  static void _deleteScriptNow(Directory? scriptDir) {
    if (scriptDir == null) return;
    try {
      scriptDir.deleteSync(recursive: true);
    } on Object {
      // Best-effort; a leaked temp dir is reaped by the OS.
    }
  }

  static void _collect(
    StringBuffer target,
    String chunk,
    void Function(String)? callback,
    Process process,
    void Function(ExecutionError) onError,
  ) {
    target.write(chunk);
    if (callback == null) return;
    try {
      callback(chunk);
    } on Object catch (error) {
      onError(
        ExecutionError(
          ExecutionErrorCode.callbackError,
          error.toString(),
          cause: error,
        ),
      );
      process.kill();
    }
  }

  /// Tail-caps a killed run's capture at the source (review thread 8):
  /// keep the last [_captureMax] bytes with a marker — the diagnostic tail
  /// of a timeout/abort. Successful runs keep the full output (this is
  /// only used for the error fields).
  static const _captureMax = 64 * 1024;

  static String _captureTail(StringBuffer buffer) {
    final s = buffer.toString();
    if (s.length <= _captureMax) return s;
    return '…[truncated]${s.substring(s.length - _captureMax)}';
  }

  static Result<ShellExecResult, ExecutionError> _result({
    required ExecutionError? callbackError,
    required bool timedOut,
    required Duration? timeout,
    required bool cancelled,
    required StringBuffer stdout,
    required StringBuffer stderr,
    required int exitCode,
    List<ShellSurvivor> survivors = const [],
  }) {
    if (callbackError != null) return Err(callbackError);
    // gh-1053 (review rework): a killed call returns the captured partial
    // output — the bounded return exists so a hung call comes back WITH
    // its evidence, not just a verdict. Capped AT THE SOURCE (review
    // thread 8): a chatty command streaming tens of MB before its timeout
    // must not keep its full output on the error object — the diagnostic
    // tail is what a bounded return needs.
    if (timedOut) {
      return Err(
        ExecutionError(
          ExecutionErrorCode.timeout,
          'timeout: $timeout',
          stdout: _captureTail(stdout),
          stderr: _captureTail(stderr),
          survivors: survivors,
        ),
      );
    }
    if (cancelled) {
      return Err(
        ExecutionError(
          ExecutionErrorCode.aborted,
          'aborted',
          stdout: _captureTail(stdout),
          stderr: _captureTail(stderr),
          survivors: survivors,
        ),
      );
    }
    return Ok(
      ShellExecResult(
        stdout: stdout.toString(),
        stderr: stderr.toString(),
        exitCode: exitCode,
        survivors: survivors,
      ),
    );
  }

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    final token = options?.cancelToken;
    if (token?.isCancelled ?? false) {
      return const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted'));
    }
    // gh-1053: start the child in its own session/process group when the
    // host can (same probe the background jobs use) — the timeout and
    // cancel paths below then reap the WHOLE tree with one group signal
    // instead of stranding a surviving grandchild on the output pipe.
    final ownGroup = LocalShell.ownProcessGroupAvailable;
    // Issue #2201: the spawn second bounds the orphan-window scan on
    // non-ownGroup hosts (macOS) — processes in our group orphaned to
    // init (ppid 1) whose start falls inside this call's window are this
    // call's survivors.
    final execStart = DateTime.now();
    final (started, _) = await _start(command, options, ownSession: ownGroup);
    if (started.isErr) return Err(started.errorOrNull!);
    final process = started.valueOrNull!;

    final stdout = StringBuffer();
    final stderr = StringBuffer();
    ExecutionError? callbackError;
    await _wireProcessStdin(process, options);
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .forEach(
          (chunk) => _collect(
            stdout,
            chunk,
            options?.onStdout,
            process,
            (error) => callbackError = error,
          ),
        );
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .forEach(
          (chunk) => _collect(
            stderr,
            chunk,
            options?.onStderr,
            process,
            (error) => callbackError = error,
          ),
        );
    // Open-pipe tracker for the kill guards below: both futures complete
    // when the pipe write end closes. A late stream error is consumed HERE
    // only for the counting future — the awaiters below keep the original
    // propagation semantics.
    var openStreams = 2;
    void streamClosed() => openStreams--;
    unawaited(
      stdoutDone.then(
        (_) => streamClosed(),
        onError: (Object _) => streamClosed(),
      ),
    );
    unawaited(
      stderrDone.then(
        (_) => streamClosed(),
        onError: (Object _) => streamClosed(),
      ),
    );
    var childGone = false;
    unawaited(process.exitCode.then((_) => childGone = true));

    Timer? timer;
    var timedOut = false;
    final timeout = options?.timeout;
    if (timeout != null) {
      timer = Timer(timeout, () {
        // The exec is fully settled: the child exited AND both pipes
        // closed — nothing to reap, never signal (mirrors the job
        // registry's isRunning check, which this approximates). With the
        // child gone but a drain still in flight the signal still fires:
        // a live group member is what's holding the pipe, so the group is
        // ours — the residual recycled-pid window (pid freed by the reap
        // and re-led before the signal lands) is theoretical and accepted,
        // as in the job path.
        if (childGone && openStreams == 0) return;
        timedOut = true;
        unawaited(_stopTree(process, ownGroup: ownGroup));
      });
    }
    void onCancel(_) {
      if (childGone && openStreams == 0) return;
      unawaited(_stopTree(process, ownGroup: ownGroup));
    }

    token?.onCancel.then(onCancel);

    final exitCode = await process.exitCode;
    // gh-1053: the timer stays ARMED after the direct child exits — an
    // orphaned descendant can hold the pipes past the child's death, and
    // this timer is what bounds the call ("≤ timeout + kill grace + drain
    // grace regardless of what descendants do"). It no-ops once the exec
    // is fully settled (guard above); the settled drain
    // cancels it below. Cancel-on-exit used to strand exactly the
    // run-36421037356 shape (shell long dead, grandchild on the pipe).
    if (options?.liveStdin != null) {
      unawaited(process.stdin.close().catchError((_) {}));
    }
    // gh-1053 (review rework): the drain is capped UNCONDITIONALLY. This
    // point is only reached after `process.exitCode` resolved, so every
    // remaining byte on the pipes comes from an ORPHANED descendant
    // holding the write end — waiting for it full-unbounded has no
    // legitimate use (a caller wanting daemon output should use
    // `run_in_bg`), with or without a timeout. The race never delays a
    // healthy call: after the child's death the pipe buffer drains in
    // milliseconds. Timeout/cancel'd calls complete in
    // ≤ timeout + _killGrace + _drainGrace; a no-timeout call in
    // ≤ child runtime + _drainGrace. No kill round for the no-timeout
    // case — a detached daemon is the caller's on purpose.
    final drained = Future.wait([stdoutDone, stderrDone]);
    await Future.any([drained, Future<void>.delayed(_drainGrace)]);
    // Once the grace won the race, a late stream error (malformed bytes
    // from the dying tree) must never surface unhandled.
    drained.ignore();
    timer?.cancel();
    // Read AFTER the waits: a cancel that lands mid-drain must still mark
    // the result (the flag used to be captured pre-drain and lost).
    final cancelled = token?.isCancelled ?? false;

    // Issue #2201: survivors of a normal exit; on a stopped/timed-out exit
    // only where the tree kill was a best-effort walk, not a group reap —
    // there the walk can miss reparented TERM-trapping grandchildren and
    // adoption must re-track them (issue #2276). Pure observation: one
    // table read, no pipe is kept open, no timer armed — the exec
    // contract (≤ timeout + grace) stands.
    var survivors = const <ShellSurvivor>[];
    if (!Platform.isWindows &&
        shouldScanSurvivors(
          stopped: timedOut || cancelled,
          ownGroup: ownGroup,
        ) &&
        callbackError == null) {
      survivors = classifyShellSurvivors(
        childPid: process.pid,
        ownGroup: ownGroup,
        ourPgid: LocalShell.ourPgid,
        execStart: execStart,
        table:
            await (processDetailTableSnapshotOverride ??
                processDetailTableSnapshot)(),
      );
    }

    return _result(
      callbackError: callbackError,
      timedOut: timedOut,
      timeout: timeout,
      cancelled: cancelled,
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      survivors: survivors,
    );
  }

  /// Feeds optional stdin data (bash tool `stdin` param: a passphrase the
  /// user supplied via the ask UI, a `y\n`). With a live stdin channel
  /// (issue #367) the pipe stays OPEN for the process's lifetime so a
  /// mid-run password ask can be answered; otherwise it closes right
  /// after start so tools like ripgrep that fall back to stdin do not
  /// hang forever.
  Future<void> _wireProcessStdin(
    Process process,
    ShellExecOptions? options,
  ) async {
    final liveStdin = options?.liveStdin;
    if (liveStdin != null) {
      liveStdin.bind(process.stdin.write);
    }
    if (options?.stdinData != null) {
      try {
        process.stdin.write(options!.stdinData);
        await process.stdin.flush();
      } on Object {
        // Process already gone — the exit path reports the real status.
      }
    }
    if (liveStdin == null) unawaited(process.stdin.close());
  }

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final token = options?.cancelToken;
    if (token?.isCancelled ?? false) {
      return const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted'));
    }
    // Issue #919 (review): build the ceiling BEFORE anything is spawned —
    // a bad ceiling used to throw after `Process.start` plus the eager log
    // open, stranding an orphan child and leaking the fd with no job
    // object to stop or settle. Here it degrades to a plain Err.
    final warn = options?.onJobLogWarning;
    final JobLogCeiling ceiling;
    try {
      ceiling = JobLogCeiling(
        maxBytes: options?.jobLogMaxBytes ?? defaultJobLogMaxBytes,
        probe: diskFreeProbe == null
            ? null
            : () => diskFreeProbe!(File(logPath).parent.path),
        onWarn: warn == null
            ? null
            : (message) => warn('background job $id: $message'),
      );
    } on ArgumentError catch (error) {
      return Err(
        ExecutionError(
          ExecutionErrorCode.spawnError,
          'invalid jobLogMaxBytes: ${error.message}',
          cause: error,
        ),
      );
    }
    final ownGroup = LocalShell.ownProcessGroupAvailable;
    final (started, _) = await _start(command, options, ownSession: ownGroup);
    if (started.isErr) return Err(started.errorOrNull!);
    final process = started.valueOrNull!;
    // Feed optional stdin data (bash tool `stdin` param). With a live
    // stdin channel (issue #367) the pipe stays OPEN for the process's
    // lifetime so a mid-run password ask can be answered; otherwise it
    // closes right after start — background jobs are not interactive
    // beyond this.
    final liveStdin = options?.liveStdin;
    if (liveStdin != null) {
      liveStdin.bind(process.stdin.write);
    }
    if (options?.stdinData != null) {
      try {
        process.stdin.write(options!.stdinData);
        await process.stdin.flush();
      } on Object {
        // Process already gone — the settle path reports the real status.
      }
    }
    if (liveStdin == null) unawaited(process.stdin.close());
    final RandomAccessFile logSink;
    try {
      // Issue #925: open the log eagerly and guard it HERE. `File.openWrite`
      // starts its open lazily-but-eagerly with no owner for the failure —
      // an error (missing directory, permissions, ENOSPC) surfaced as an
      // unlistened future and reached the root-zone handler, killing the
      // whole fa process. An awaited open turns every open-class failure
      // into this clean Err instead.
      logSink = await File(logPath).open(mode: FileMode.append);
    } on Object catch (error) {
      process.kill();
      return Err(
        ExecutionError(
          ExecutionErrorCode.spawnError,
          'cannot open job log file $logPath: $error',
          cause: error,
        ),
      );
    }
    // Issue #919: bound the log — the ceiling (size ceiling with
    // head+marker+rolling tail, plus the low-disk guard with the probe
    // injectable via [LocalShell]) was built pre-spawn above.
    return Ok(
      _LocalShellJob(
        id: id,
        command: command,
        logPath: logPath,
        process: process,
        logSink: logSink,
        ceiling: ceiling,
        ownGroup: ownGroup,
        timeout: options?.timeout,
        token: token,
        redactor: options?.jobLogRedactor,
      ),
    );
  }
}

/// A [ShellJob] over a local [Process]: stdout/stderr stream into the log
/// file; timeout and the cancel token both stop the process.
final class _LocalShellJob implements ShellJob, SurvivorReporting {
  _LocalShellJob({
    required this.id,
    required this.command,
    required this.logPath,
    required this._process,
    required this._logSink,
    required this._ceiling,
    required this._ownGroup,
    Duration? timeout,
    CancelToken? token,
    this._redactor,
  }) : _execStart = DateTime.now() {
    // Collect stdout/stderr into the log file. A naturally exiting process
    // closes the streams and we flush every byte; a killed/timed-out process
    // may leave the streams dangling on some platforms, so we cap the drain
    // wait and then cancel the subscriptions.
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    // Issue #925: a log write failure (disk full, removed file, closed
    // handle) must never escape into the zone — the error of every write
    // is consumed here and the job keeps running headless, its log frozen
    // at the last successful chunk. RandomAccessFile allows one op at a
    // time, so writes serialize through the chain and the settle path
    // drains it before flush/close.
    //
    // Issue #919: chunks flow through the ceiling policy first — below the
    // ceiling it yields the plain append (byte-identical to the old
    // `writeString(chunk)`); past it, patch ops that keep the file bounded
    // while the job keeps running. A write stop (low disk) yields no ops.
    // Issue #1408 AC2: before the ceiling, the redactor (when configured)
    // masks secret-shaped text — the RESTING file never stores raw secret
    // values. The live `_output` stream stays raw (it feeds transient
    // consumers like the password detector; at-rest is the contract here).
    void fanOut(String chunk) {
      // A broken log no longer ingests (review 5456649624): the carry
      // would only grow for text that can never rest anywhere.
      final safe = _logBroken ? chunk : (_redactor?.ingest(chunk) ?? chunk);
      if (!_logBroken && safe.isNotEmpty) {
        _writeChain = _writeChain
            .then((_) => _ceiling.ingest(safe))
            .then(
              (ops) async {
                for (final op in ops) {
                  await _applyLogWrite(op);
                }
              },
              onError: (Object _) {
                _logBroken = true;
              },
            );
      }
      _output.add(chunk);
    }

    _stdoutSub = _process.stdout
        .transform(utf8.decoder)
        .listen(
          fanOut,
          onError: (_) {},
          onDone: () {
            if (!stdoutDone.isCompleted) stdoutDone.complete();
          },
        );
    _stderrSub = _process.stderr
        .transform(utf8.decoder)
        .listen(
          fanOut,
          onError: (_) {},
          onDone: () {
            if (!stderrDone.isCompleted) stderrDone.complete();
          },
        );
    if (timeout != null) {
      _timer = Timer(timeout, () {
        _stopReason = 'timeout';
        stop();
      });
    }
    token?.onCancel.then((_) {
      _stopReason = 'cancelled';
      stop();
    });
    unawaited(
      _process.exitCode.then((code) async {
        _exitCode = code;
        _timer?.cancel();
        // Wait for the streams to drain, but cap it so a killed process
        // cannot hang settled forever.
        await Future.any([
          Future.wait([stdoutDone.future, stderrDone.future]),
          Future.delayed(const Duration(milliseconds: 500)),
        ]);
        await _stdoutSub.cancel();
        await _stderrSub.cancel();
        unawaited(_process.stdin.close().catchError((_) {}));
        await _output.close();
        // Issue #925: the settle path runs inside an unawaited future — a
        // throwing flush/close escaped to the root zone AND left _settled
        // incomplete (the job board showed the job as running forever).
        // Drain pending writes first (RAF allows one op at a time), then
        // swallow every sink failure and settle regardless.
        await _writeChain;
        // Issue #1408 AC2: the redactor's buffered partial line (a final
        // output chunk without its newline) still belongs in the log.
        if (!_logBroken && _redactor != null) {
          try {
            final rest = _redactor.flush();
            if (rest.isNotEmpty) {
              final ops = await _ceiling.ingest(rest);
              for (final op in ops) {
                await _applyLogWrite(op);
              }
            }
          } on Object {
            _logBroken = true;
          }
        }
        // Issue #919: final tail patch — the exact dropped count.
        if (!_logBroken) {
          try {
            final finalOp = _ceiling.settleFlush();
            if (finalOp != null) await _applyLogWrite(finalOp);
          } on Object {
            _logBroken = true;
          }
        }
        // Guarded separately so a failed flush never skips close() — a
        // leaked RAF fd would live for the whole fa process (issue #925).
        try {
          await _logSink.flush();
        } on Object {
          _logBroken = true;
        }
        try {
          await _logSink.close();
        } on Object {
          _logBroken = true;
        }
        // Issue #2201: survivors of a normal exit; after a stop only on
        // hosts without group leadership — there the walk-based tree kill
        // can miss reparented TERM-trapping grandchildren, and adoption
        // re-tracks them instead of "Stopped" lying (issue #2276). On
        // ownGroup hosts the group kill reaped everything (gh-1053).
        // Buffered for the registry's settle listener; one `ps` round on
        // POSIX, nothing on Windows.
        if (!Platform.isWindows &&
            LocalShell.shouldScanSurvivors(
              stopped: _stopReason != null,
              ownGroup: _ownGroup,
            )) {
          _survivors = classifyShellSurvivors(
            childPid: _process.pid,
            ownGroup: _ownGroup,
            ourPgid: LocalShell.ourPgid,
            execStart: _execStart,
            table:
                await (LocalShell.processDetailTableSnapshotOverride ??
                    processDetailTableSnapshot)(),
          );
        }
        _settled.complete();
      }),
    );
  }

  final Process _process;
  final RandomAccessFile _logSink;
  final JobLogCeiling _ceiling;

  /// This job's spawn moment (issue #2201): the lower bound of the
  /// orphan-window survivor scan on non-ownGroup hosts.
  final DateTime _execStart;

  /// Survivors observed at this job's normal exit, consumed once by the
  /// registry's settle listener ([SurvivorReporting.takeSurvivors]).
  List<ShellSurvivor> _survivors = const [];

  /// At-rest log redaction (issue #1408 AC2); null keeps raw bytes.
  final JobLogRedactor? _redactor;

  /// Executes one ceiling op against the sink: a plain append at the
  /// advancing position, or an in-place overwrite of the marker+tail
  /// region (Dart's append-mode RAF honors setPosition/truncate, so the
  /// file never needs reopening). Region overwrites also truncate to the
  /// new region end, keeping the file exactly bounded.
  Future<void> _applyLogWrite(JobLogWrite op) async {
    if (op.offset == null) {
      await _logSink.writeString(op.text);
      return;
    }
    await _logSink.setPosition(op.offset!);
    await _logSink.writeString(op.text);
    await _logSink.truncate(op.offset! + utf8.encode(op.text).length);
  }

  /// Set on the first log-sink failure (issue #925): the job keeps
  /// running but its log stays frozen at the last successful write.
  bool _logBroken = false;

  /// Serialized log writes (issue #925): RandomAccessFile forbids
  /// overlapping ops, and the settle path drains this before flush/close.
  Future<void> _writeChain = Future<void>.value();

  /// Whether the job is its own session/process-group leader (`setsid`
  /// spawn) — stop() then signals the whole group, not a pid walk.
  final bool _ownGroup;
  final _output = StreamController<String>.broadcast();
  late final StreamSubscription<void> _stdoutSub;
  late final StreamSubscription<void> _stderrSub;
  Timer? _timer;
  final _settled = Completer<void>();
  int? _exitCode;
  String? _stopReason;

  @override
  final String id;

  @override
  final String command;

  @override
  final String logPath;

  @override
  int? get pid => _process.pid;

  @override
  bool get isRunning => _exitCode == null;

  @override
  int? get exitCode => _exitCode;

  @override
  String? get stopReason => _stopReason;

  @override
  Future<void> get settled => _settled.future;

  @override
  Future<void> stop() async {
    // Already settled: never signal — the pid may have been recycled.
    if (!isRunning) return;
    _stopReason ??= 'stopped';
    await LocalShell.killTree(_process.pid, ownGroup: _ownGroup);
    // Backstop for the direct child, whatever the tree path did.
    _process.kill();
  }

  @override
  Stream<String> get output => _output.stream;

  @override
  List<ShellSurvivor> takeSurvivors() {
    final out = _survivors;
    _survivors = const [];
    return out;
  }

  @override
  bool writeStdin(String data) {
    if (!isRunning) return false;
    return _tryWriteStdin(data);
  }

  /// Writes [data] to the live process's stdin; false when the pipe
  /// rejects the write (the process settled between the [isRunning] check
  /// and the write — the exit race).
  bool _tryWriteStdin(String data) {
    try {
      _process.stdin.write(data);
      return true;
    } on Object {
      return false;
    }
  }
}

/// Local [ExecutionEnv]: [LocalFileSystem] plus [LocalShell].
///
/// Exported only from `lib/io.dart`.
final class LocalExecutionEnv
    implements
        ExecutionEnv,
        BackgroundShell,
        RangedReadFileSystem,
        RenamableFileSystem,
        ExclusiveCreateFileSystem {
  /// Creates a [LocalExecutionEnv] rooted at [cwd].
  ///
  /// A custom [shell] may be provided to swap the default [LocalShell] for a
  /// sandboxed WASM shell on mobile targets. [diskFreeProbe] backs the
  /// job-log low-disk guard of the default shell (issue #919); injectable
  /// for tests, ignored when [shell] is given.
  LocalExecutionEnv({String? cwd, Shell? shell, this.diskFreeProbe})
    : _fs = LocalFileSystem(cwd: cwd),
      _shell =
          shell ??
          (diskFreeProbe == null
              ? const LocalShell()
              : LocalShell(diskFreeProbe: diskFreeProbe));

  /// Low-disk probe for background-job logs (issue #919); null = default
  /// `df`-based probe.
  final Future<int?> Function(String directory)? diskFreeProbe;

  final LocalFileSystem _fs;
  final Shell _shell;

  @override
  String get cwd => _fs.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _fs.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _fs.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _fs.readTextFile(path);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _fs.readBinaryFile(path);

  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) => _fs.readRange(path, start, end);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _fs.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _fs.writeFile(path, content);

  @override
  Future<Result<void, FileError>> renamePath(String from, String to) =>
      _fs.renamePath(from, to);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _fs.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _fs.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _fs.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _fs.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => _fs.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _fs.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> createFileExclusive(String path) =>
      _fs.createFileExclusive(path);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _fs.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _shell.exec(command, options: options);

  @override
  bool get backgroundJobsSupported {
    final shell = _shell;
    if (shell case final BackgroundShell bg) return bg.backgroundJobsSupported;
    return false;
  }

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) {
    final shell = _shell;
    if (shell case final BackgroundShell bg) {
      return bg.startShellJob(
        command,
        id: id,
        logPath: logPath,
        options: options,
      );
    }
    // A swapped-in shell (e.g. the sandboxed WASM shell) without the
    // background capability: clean error, never a crash.
    return Future.value(
      const Err(
        ExecutionError(
          ExecutionErrorCode.shellUnavailable,
          'background shell jobs are not supported by this shell',
        ),
      ),
    );
  }
}
