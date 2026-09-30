/// Streaming size ceiling for background shell-job logs (issue #919).
///
/// A runaway background job once grew a single `.fah/bash_jobs/<id>.log` to
/// 335 GB and crashed the host with `errno 28`. This policy bounds the log:
/// below the ceiling every chunk appends byte-identically to today; on
/// crossing, the writer switches to truncation mode — the head (first bytes)
/// stays, one visible marker is placed at the seam, and afterwards only a
/// rolling in-memory tail is kept, patched into a bounded tail region. The
/// job itself is never killed: output capture degrades, execution continues.
///
/// Pure Dart — no `dart:io`. The hosts ([LocalShell] jobs and the sandbox
/// `SandboxShellJob`s) feed chunks through [ingest] and execute the returned
/// [JobLogWrite] ops against their own sink; the low-disk probe is injected
/// ([DiskFreeProbe], default impl `diskFreeBytes` in `lib/io.dart`), so web
/// builds (memory filesystem) share the exact same ceiling logic.
///
/// File layout once truncated: `[head bytes][marker line][rolling tail]`.
/// Both hosts patch the marker+tail region in place, so the file size never
/// exceeds roughly [maxBytes] regardless of how much the job produces.
///
/// UTF-8 (edge case E1): chunks arrive as decoded strings and truncation
/// points are chunk boundaries, so the head never splits a sequence; the
/// tail is trimmed at sequence boundaries ([_trimTail]). The resting file is
/// always valid UTF-8 — readers only see the marker line as content (E4).
library;

import 'dart:convert';
import 'dart:typed_data';

/// Default `jobs.maxLogBytes` (issue OQ1: 50 MB — readable in an editor,
/// large enough for build logs).
const defaultJobLogMaxBytes = 50 * 1024 * 1024;

/// Low-disk safety threshold: when the filesystem holding the log has less
/// free space, log writes stop (the job keeps running). Fixed constant for
/// now — every harness shares one host disk.
const defaultJobLogMinFreeBytes = 1024 * 1024 * 1024;

/// Free-space probe cadence: re-check at most once per this many produced
/// bytes per job (aggregate backstop for many concurrent jobs, E3).
const jobLogFreeCheckEveryBytes = 1024 * 1024;

/// Rolling-tail flush cadence floor: after truncation, the marker+tail
/// region is patched at most once per max(tail ~/ 2, this many) new tail
/// bytes — so the region rewrite is bounded at ≤ ~2× write amplification
/// at any ceiling (issue #919 review: a fixed 64 KiB cadence under a
/// ceiling-proportional tail meant ~195× at the 50 MB default). This floor
/// keeps tiny-ceiling tails from flushing on every small chunk.
const jobLogTailFlushEveryBytes = 64 * 1024;

/// Marker written once at the truncation seam. `X` is patched in place as
/// the exact dropped count becomes known (final at settle) — the marker
/// LINE is written exactly once per truncation event (E2).
String jobLogTruncationMarker(int bytesDropped) =>
    '[… log truncated: $bytesDropped bytes dropped …]\n';

/// Reserve for the marker line inside the ceiling budget (the widest
/// realistic marker is ~50 bytes; 128 leaves headroom).
const _markerReserveBytes = 128;

/// Upper bound on the rolling tail regardless of the ceiling: keeps the
/// per-flush region rewrite small at large ceilings (a 50 MB ceiling with
/// a 12.5 MB tail rewritten on every flush would turn the runaway-job path
/// into heavy write amplification — the exact #919 scenario).
const _maxTailBytes = 1024 * 1024;

/// Queries the free space (in bytes) of the filesystem holding the job
/// log's directory. Returns null when unknown (probe unavailable,
/// unsupported platform) — the guard then stays inactive. Injectable for
/// tests; hosts bind the directory (`diskFreeBytes(dir)` from lib/io.dart).
typedef DiskFreeProbe = Future<int?> Function();

/// One bounded-log mutation for the host to execute against its sink.
final class JobLogWrite {
  const JobLogWrite.append(this.text) : offset = null;

  const JobLogWrite.patch(this.offset, this.text);

  /// Byte offset to overwrite at; null means append at the end.
  final int? offset;

  /// Text to write (UTF-8 on the wire).
  final String text;
}

/// The streaming truncation policy. See the library doc.
final class JobLogCeiling {
  /// Creates a ceiling policy. [maxBytes] caps the log and must be > 0;
  /// [probe] (optional — absent on web) enables the low-disk guard with
  /// [minFreeBytes]; [onWarn] fires at most once per job when the guard
  /// stops writes.
  JobLogCeiling({
    this.maxBytes = defaultJobLogMaxBytes,
    this.minFreeBytes = defaultJobLogMinFreeBytes,
    this.probe,
    this.onWarn,
  }) : _tailBudget = _tailBudgetFor(maxBytes),
       _headBudget = _headBudgetFor(maxBytes) {
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must be > 0');
    }
  }

  /// Log size ceiling in produced bytes.
  final int maxBytes;

  /// Free-space threshold under which log writes stop.
  final int minFreeBytes;

  /// Injected free-space probe; null disables the guard (web).
  final DiskFreeProbe? probe;

  /// Fires at most once per job when the low-disk guard stops writes.
  final void Function(String message)? onWarn;

  /// Head keeps everything up to this byte count before the seam. The tail
  /// keeps the last [maxBytes]/4 bytes, capped at [_maxTailBytes] so the
  /// patched region stays small at large ceilings.
  final int _tailBudget;
  final int _headBudget;

  static int _tailBudgetFor(int maxBytes) {
    final budget = maxBytes ~/ 4;
    return budget > _maxTailBytes ? _maxTailBytes : budget;
  }

  static int _headBudgetFor(int maxBytes) {
    final tail = _tailBudgetFor(maxBytes);
    final head = maxBytes - tail - _markerReserveBytes;
    return head > 0 ? head : 0;
  }

  /// Region-rewrite cadence: half the tail, floored at the 64 KiB minimum —
  /// patches land at most once per this many new tail bytes, so write
  /// amplification stays ≤ ~2× (one region rewrite per tail/2 bytes
  /// produced) at any ceiling.
  int get _tailFlushEveryBytes {
    final half = _tailBudget ~/ 2;
    return half > jobLogTailFlushEveryBytes ? half : jobLogTailFlushEveryBytes;
  }

  /// Total produced bytes so far (stdout + stderr).
  int get producedBytes => _produced;
  int _produced = 0;

  /// True once the stream crossed the ceiling.
  bool get truncated => _truncated;
  bool _truncated = false;

  /// True once the low-disk guard stopped log writes.
  bool get writesStopped => _writesStopped;
  bool _writesStopped = false;

  bool _warned = false;
  int _headBytes = 0;
  int _markerOffset = 0;
  int _lastProbeAt = -1;
  int _unflushedTail = 0;
  final List<int> _tail = <int>[];

  /// Ingests one decoded chunk and returns the ops to execute, in order.
  /// Must be called serially (the hosts chain it).
  Future<List<JobLogWrite>> ingest(String chunk) async {
    if (_writesStopped) return const [];
    if (!await _checkFreeSpace()) return const [];
    final bytes = utf8.encode(chunk);
    _produced += bytes.length;
    if (!_truncated) {
      if (_headBytes + bytes.length <= _headBudget) {
        _headBytes += bytes.length;
        return [JobLogWrite.append(chunk)];
      }
      return [_cross(bytes)];
    }
    _tail.addAll(bytes);
    _unflushedTail += bytes.length;
    _trimTail();
    if (_unflushedTail < _tailFlushEveryBytes) return const [];
    _unflushedTail = 0;
    return [_patchOp()];
  }

  /// Final patch with the exact dropped count — call after the write chain
  /// drains, before flush/close. Null when truncation never happened (the
  /// low-disk stop leaves the log frozen with no marker to fix up).
  JobLogWrite? settleFlush() => _truncated ? _patchOp() : null;

  /// Crossing: append the marker + initial tail right after the head.
  JobLogWrite _cross(Uint8List bytes) {
    _truncated = true;
    _markerOffset = _headBytes;
    _tail.addAll(bytes);
    _trimTail();
    _unflushedTail = 0;
    return JobLogWrite.append(_regionText());
  }

  JobLogWrite _patchOp() => JobLogWrite.patch(_markerOffset, _regionText());

  /// The marker line plus the current tail — the patched region.
  String _regionText() =>
      jobLogTruncationMarker(_produced - _headBytes - _tail.length) +
      utf8.decode(_tail);

  /// Drops tail bytes beyond the budget, forward to a UTF-8 sequence
  /// boundary so the tail always decodes cleanly (E1).
  void _trimTail() {
    if (_tail.length <= _tailBudget) return;
    var cut = _tail.length - _tailBudget;
    while (cut < _tail.length && (_tail[cut] & 0xC0) == 0x80) {
      cut++;
    }
    _tail.removeRange(0, cut);
  }

  /// Low-disk guard: checked on the first chunk and then once per
  /// [jobLogFreeCheckEveryBytes], only while the file can still GROW —
  /// once truncated, patches never grow the file, so the guard is moot.
  Future<bool> _checkFreeSpace() async {
    final probe = this.probe;
    if (probe == null || _truncated) return true;
    if (_lastProbeAt >= 0 &&
        _produced - _lastProbeAt < jobLogFreeCheckEveryBytes) {
      return true;
    }
    _lastProbeAt = _produced;
    final int? free;
    try {
      free = await probe();
    } on Object {
      return true; // Probe failed — guard stays inactive, never kills capture.
    }
    if (free == null || free >= minFreeBytes) return true;
    _writesStopped = true;
    if (!_warned) {
      _warned = true;
      onWarn?.call(
        'free disk space is low (${free ~/ 1024} kB free, threshold '
        '${minFreeBytes ~/ (1024 * 1024)} MB) — job log writes stopped; '
        'the job keeps running with degraded capture',
      );
    }
    return false;
  }
}
