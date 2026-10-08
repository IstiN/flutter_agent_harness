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
import 'execution_env.dart';
import 'free_space_io.dart';
import 'job_log_ceiling.dart';
import 'job_log_redaction.dart';

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

FileError _fromFileSystemException(FileSystemException error, String path) {
  final osError = error.osError;
  if (osError != null) {
    // EPERM / EACCES on POSIX; ERROR_ACCESS_DENIED (5) on Windows.
    if (osError.errorCode == 13 ||
        osError.errorCode == 1 ||
        osError.errorCode == 5) {
      return FileError(
        FileErrorCode.permissionDenied,
        error.message,
        path: path,
        cause: error,
      );
    }
    // ENOTDIR on POSIX.
    if (osError.errorCode == 20) {
      return FileError(
        FileErrorCode.notDirectory,
        error.message,
        path: path,
        cause: error,
      );
    }
  }
  return FileError(
    FileErrorCode.unknown,
    error.message,
    path: path,
    cause: error,
  );
}

/// Local-disk [FileSystem] backed by `dart:io`.
///
/// Relative paths resolve against [cwd] (default: the process working
/// directory). All operations uphold the [FileSystem] never-throw invariant.
final class LocalFileSystem
    implements FileSystem, RangedReadFileSystem, RenamableFileSystem {
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
          name: resolved.split('/').last,
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
  /// walk; Windows delegates to `taskkill /T`. TERM first, a short grace,
  /// then KILL. Best-effort: never throws.
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
      var victims = await _descendantsOf(pid);
      if (victims.isEmpty) return;
      await _signalAll(victims, ProcessSignal.sigterm);
      await Future<void>.delayed(_killGrace);
      // Children may have been forked while the first round landed; the
      // walk only roots at a still-observable pid, so a recycled root can
      // never widen the victim set.
      victims = await _descendantsOf(pid);
      await _signalAll(victims, ProcessSignal.sigkill);
    } on Object {
      // Best-effort: stop() still backstops the direct child.
    }
  }

  /// [root] plus every live descendant, via one `ps` ppid scan. Empty when
  /// [root] is gone (its pid is recycled only after reaping, and the scan
  /// roots at an observable row — never at a stranger).
  static Future<Set<int>> _descendantsOf(int root) async {
    final ps = await Process.run('ps', ['-ax', '-o', 'pid=,ppid=']);
    final parentOf = <int, int>{};
    for (final line in (ps.stdout as String).split('\n')) {
      final cols = line.trim().split(RegExp(r'\s+'));
      if (cols.length < 2) continue;
      final pid = int.tryParse(cols[0]);
      final ppid = int.tryParse(cols[1]);
      if (pid != null && ppid != null) parentOf[pid] = ppid;
    }
    if (!parentOf.containsKey(root)) return const {};
    final children = <int, List<int>>{};
    parentOf.forEach((pid, ppid) {
      children.putIfAbsent(ppid, () => <int>[]).add(pid);
    });
    final out = <int>{root};
    final queue = <int>[root];
    while (queue.isNotEmpty) {
      for (final child in children[queue.removeAt(0)] ?? const <int>[]) {
        if (out.add(child)) queue.add(child);
      }
    }
    return out;
  }

  static Future<void> _signalAll(Set<int> pids, ProcessSignal signal) async {
    for (final pid in pids) {
      try {
        Process.killPid(pid, signal);
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
  static Map<String, String> _environment(ShellExecOptions? options) {
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
    const nonInteractiveDefaults = {
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_ASKPASS': 'echo',
    };
    for (final entry in nonInteractiveDefaults.entries) {
      if (given == null || !given.containsKey(entry.key)) {
        base[entry.key] = entry.value;
      }
    }
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
    return base;
  }

  static Future<Result<Process, ExecutionError>> _start(
    String command,
    ShellExecOptions? options, {
    bool ownSession = false,
  }) async {
    // ownSession (issue #517): `setsid` makes the job its own session and
    // process-group leader — pgid == pid — so stop() can signal the whole
    // tree and the boot sweep can recognize leftover groups. setsid execs
    // sh in place, so the spawned pid is still the tracked one.
    final executable = Platform.isWindows
        ? 'cmd'
        : ownSession
        ? 'setsid'
        : 'sh';
    final args = Platform.isWindows
        ? ['/c', command]
        : ownSession
        ? ['sh', '-c', command]
        : ['-c', command];
    try {
      return Ok(
        await Process.start(
          executable,
          args,
          workingDirectory: options?.cwd,
          environment: _environment(options),
        ),
      );
    } on Object catch (error) {
      return Err(
        ExecutionError(
          ExecutionErrorCode.spawnError,
          error.toString(),
          cause: error,
        ),
      );
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
        ),
      );
    }
    return Ok(
      ShellExecResult(
        stdout: stdout.toString(),
        stderr: stderr.toString(),
        exitCode: exitCode,
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
    final started = await _start(command, options, ownSession: ownGroup);
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

    return _result(
      callbackError: callbackError,
      timedOut: timedOut,
      timeout: timeout,
      cancelled: cancelled,
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
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
    final started = await _start(command, options, ownSession: ownGroup);
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
        timeout: options?.timeout,
        token: token,
        ownGroup: ownGroup,
        redactor: options?.jobLogRedactor,
      ),
    );
  }
}

/// A [ShellJob] over a local [Process]: stdout/stderr stream into the log
/// file; timeout and the cancel token both stop the process.
final class _LocalShellJob implements ShellJob {
  _LocalShellJob({
    required this.id,
    required this.command,
    required this.logPath,
    required Process process,
    required this._logSink,
    required this._ceiling,
    required this._ownGroup,
    Duration? timeout,
    CancelToken? token,
    JobLogRedactor? redactor,
  }) : _process = process,
       _redactor = redactor {
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

    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .listen(
          fanOut,
          onError: (_) {},
          onDone: () {
            if (!stdoutDone.isCompleted) stdoutDone.complete();
          },
        );
    _stderrSub = process.stderr
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
        _settled.complete();
      }),
    );
  }

  final Process _process;
  final RandomAccessFile _logSink;
  final JobLogCeiling _ceiling;

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
  bool writeStdin(String data) {
    if (!isRunning) return false;
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
        RenamableFileSystem {
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
