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
/// contending with the user's own git work; the timeout bounds a wedged
/// filesystem so the band composer can never stall on it.
Future<String?> _runGitStatus(String cwd) async {
  try {
    final result = await Process.run('git', const [
      '--no-optional-locks',
      'status',
      '--porcelain',
      '-b',
    ], workingDirectory: cwd).timeout(const Duration(seconds: 3));
    return result.exitCode == 0 ? result.stdout as String : null;
  } on Object {
    return null;
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
  /// null result (outside a repo, failure) caches for [ttl] like any
  /// other, so a non-repo directory never polls more than once per ttl.
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
    final output = await _run(cwd);
    _inFlight = false;
    _fetchedAt = _now();
    // Single flight: _probedCwd cannot change mid-refresh (current()
    // is gated on !_inFlight), so this result is always the newest.
    if (output != null) _value = parseGitStatusPorcelain(output);
  }
}
