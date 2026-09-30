/// The host-side git probe feeding the status bar's `git` segment
/// (issue #920 — the branch name, "optional if detected"): a TTL-cached,
/// stale-while-revalidate `git status` poll. Lives OUTSIDE
/// [TuiStatusLine] (the engine stays pure — zero IO) and runs git
/// OUTSIDE the agent's shell stream — infrastructure evidence, never a
/// recorded command (the process_probe_io rule).
library;

import 'dart:async';
import 'dart:io';

import 'tui_status_line.dart' show StatusLineGit, parseGitStatusPorcelain;

/// Reads the working-tree state for [cwd]: porcelain stdout on success,
/// null on any failure (no git, outside a repo, timeout). Injectable so
/// tests run without a binary.
typedef GitStatusRunner = Future<String?> Function(String cwd);

/// The default runner: `git --no-optional-locks status --porcelain -b`
/// (v1 porcelain — [parseGitStatusPorcelain]'s fixture format, `-b` for
/// the `## branch` header). `--no-optional-locks` keeps the probe from
/// contending with the user's own git work.
///
/// The deadline bounds the PROCESS, not just the await: `Future.timeout`
/// cannot cancel the spawned git, so a wedged filesystem would leave one
/// orphan per ttl cycle. Kill at the deadline instead (#923 round 1).
Future<String?> _runGitStatus(String cwd) async {
  try {
    final proc = await Process.start('git', const [
      '--no-optional-locks',
      'status',
      '--porcelain',
      '-b',
    ], workingDirectory: cwd);
    final killTimer = Timer(const Duration(seconds: 3), proc.kill);
    unawaited(proc.stderr.drain<void>()); // never block the pipe on stderr
    final stdout = await proc.stdout.transform(systemEncoding.decoder).join();
    final exitCode = await proc.exitCode;
    killTimer.cancel();
    return exitCode == 0 ? stdout : null;
  } on Object {
    return null; // no git binary, killed at the deadline, stream error
  }
}

/// The lazy slice of the #802 git-watcher seam: no watcher, a 5 s TTL
/// poll that the sync snapshot builder serves from cache.
///
// ponytail: 5 s poll, one in flight; a real watcher (inotify/FSEvents)
// only if refresh latency ever matters.
final class StatusLineGitProbe {
  StatusLineGitProbe({
    GitStatusRunner? run,
    DateTime Function()? now,
    this.ttl = const Duration(seconds: 5),
  }) : _run = run ?? _runGitStatus,
       _now = now ?? DateTime.now;

  final GitStatusRunner _run;
  final DateTime Function() _now;

  /// How long a cached state is served before the next poll.
  final Duration ttl;

  StatusLineGit? _value;
  String? _probedCwd;
  DateTime _fetchedAt = DateTime.fromMicrosecondsSinceEpoch(0);
  bool _inFlight = false;

  /// The cached state for [cwd] — sync and never blocking: the first
  /// frames render `git` hidden, the branch appears once the first poll
  /// lands and the band repaints. A cwd switch re-probes immediately; a
  /// null result (outside a repo, failure) hides the segment and only
  /// throttles the NEXT poll to [ttl], so a non-repo directory never
  /// polls more than once per ttl.
  StatusLineGit? current(String cwd) {
    if (!_inFlight &&
        (_probedCwd != cwd || _now().difference(_fetchedAt) >= ttl)) {
      _inFlight = true;
      _probedCwd = cwd;
      unawaited(_refresh(cwd));
    }
    return _value;
  }

  Future<void> _refresh(String cwd) async {
    String? output;
    try {
      output = await _run(cwd);
    } on Object {
      output = null; // a throwing custom runner is a failure, not a crash
    }
    _inFlight = false;
    _fetchedAt = _now();
    // A failure is the freshest truth for this cwd: the previous value
    // must stop rendering (without this clear, repo A's branch sticks
    // forever after a move to a non-repo — #923 round 1, blocking).
    _value = output == null ? null : parseGitStatusPorcelain(output);
  }
}
