/// Per-session request blobs (gh-1745): the heavy half of the outbound
/// request capture — per-message previews/block texts and the opt-in raw
/// wire dump — leaves the primary session JSONL and lands in
/// `.fah/trajectories/<sid>/requests/<n>.json` under a TTL / max-bytes
/// rotation policy. The persisted `model_request_summary` record keeps
/// lightweight metadata (counts, sizes, tool names, blob hashes) plus a
/// `spillFile` pointer ([stripTrajectoryRequestDetail]), which is what
/// keeps marathon sessions from growing to hundreds of MB of unrotated
/// raw prompt dumps in one JSONL.
///
/// IO contract mirrors the tool-result spill store (issue #678): pure
/// Dart over [ExecutionEnv] (no dart:io), every failure degrades to null
/// or a no-op — a failed spill write falls back to the legacy inline
/// persistence, never a crash. Kill switch: `trajectory.requestBlobs:
/// false` (hosts then persist inline byte-identically, as before).
library;

import 'dart:convert';

import '../env/execution_env.dart';
import 'trajectory_blobs.dart';
import 'trajectory_record.dart';

/// Default per-session byte budget of the requests blob dir (gh-1745):
/// "max 50MB per session" from the ticket.
const int trajectoryRequestBlobMaxBytes = 50 << 20;

/// Default age bound of one request blob (gh-1745): "keep last N days"
/// from the ticket.
const int trajectoryRequestBlobTtlDays = 30;

/// Relative dir of one session's request blobs. A null session id (the
/// capture raced the session's creation) degrades to the shared
/// `sessionless` dir — the same convention the tool-result spill uses.
String trajectoryRequestBlobDir(String? sessionId) =>
    '.fah/trajectories/${sessionId ?? 'sessionless'}/requests';

/// Relative root of every session's request-blob dir (the boot-time TTL
/// sweep walks its `<session>/requests` children).
const String trajectoryRequestBlobsRoot = '.fah/trajectories';

/// The outcome of one successful [TrajectoryRequestBlobStore.write]: the
/// blob path for the summary's `spillFile` pointer and, when the request
/// carried a raw wire dump, its content hash (the summary's
/// `wireDumpHash` — renders resolve it through the spilled file).
final class TrajectoryRequestSpill {
  /// Creates a spill outcome.
  const TrajectoryRequestSpill({required this.file, this.wireDumpHash});

  /// Relative path of the written blob (the `spillFile` pointer).
  final String file;

  /// Content hash of the stored wire dump; null when the request carried
  /// no raw dump.
  final String? wireDumpHash;
}

/// Writes and rotates one session's request blobs over [ExecutionEnv].
final class TrajectoryRequestBlobStore {
  /// Creates a store. [sessionId] resolves lazily per write (the capture
  /// can fire before the session exists); [maxBytes] bounds the dir's
  /// total size, [ttlDays] its age — the rotation policy sweeps only when
  /// a write crosses the budget or a sweep hour elapses, so a healthy
  /// session never pays a per-request directory walk.
  TrajectoryRequestBlobStore({
    required ExecutionEnv env,
    required String? Function() sessionId,
    this.maxBytes = trajectoryRequestBlobMaxBytes,
    this.ttlDays = trajectoryRequestBlobTtlDays,
    DateTime Function()? clock,
  }) :
       // ignore: prefer_initializing_formals
       _env = env,
       // ignore: prefer_initializing_formals
       _sessionId = sessionId,
       _clock = clock ?? DateTime.now;

  final ExecutionEnv _env;
  final String? Function() _sessionId;
  final DateTime Function() _clock;

  /// Per-session blob-dir byte budget.
  final int maxBytes;

  /// Blob age bound in days.
  final int ttlDays;

  String? _counterSession;
  int _counter = 0;
  var _bytesSinceSweep = 0;
  DateTime? _lastSweepAt;
  var _bootSwept = false;

  /// Writes [detail] (plus the built [rawWireDump], when the request
  /// carried one) as one JSON blob and returns the spill outcome. Null on
  /// any write failure — the caller falls back to the legacy inline
  /// persistence (AC6 shape: the capture is never lost, never a crash).
  ///
  /// [redactWireDump] is the host's active pipeline pass (E1: the dump is
  /// redacted under the config active at capture time) and the dump rides
  /// the same [wireDumpMaxChars] cap as the inline record did.
  ///
  /// The FIRST write of a store instance also runs the boot-time TTL
  /// sweep ([sweepOncePerBoot]) — the store is built lazily at the first
  /// request of a session, so hosts need no extra wiring.
  Future<TrajectoryRequestSpill?> write({
    required TrajectoryRequestDetail detail,
    String? rawWireDump,
    String Function(String)? redactWireDump,
  }) async {
    await sweepOncePerBoot();
    final dump = rawWireDump == null
        ? null
        : trajectoryBuildWireDump(rawWireDump, redact: redactWireDump);
    final payload = jsonEncode({
      'detail': detail.toJson(),
      if (dump != null) 'wireDump': dump.toJson(),
    });
    final sid = _sessionId();
    if (_counterSession != sid) {
      _counterSession = sid;
      _counter = 0;
    }
    if (_counter == 0) {
      // Sequence numbers must survive a process restart on a resumed
      // session: probe the dir once and continue past the highest
      // existing file (a failed probe starts at 1 — worst case a legacy
      // file of the same name is superseded, never merged).
      _counter = await _maxExistingSequence(sid);
    }
    _counter++;
    final file = '${trajectoryRequestBlobDir(sid)}/$_counter.json';
    final written = await _env.writeBinaryFile(file, utf8.encode(payload));
    if (written.isErr) return null;
    await _maybeSweep(payload.length);
    return TrajectoryRequestSpill(file: file, wireDumpHash: dump?.hash);
  }

  /// The full detail stored in [path]; null when the file is missing or
  /// corrupt (a rotated-away or torn blob degrades the Request tab to the
  /// record's lightweight metadata — never a crash).
  Future<TrajectoryRequestDetail?> readDetail(String path) async {
    final map = await _readJson(path);
    if (map == null) return null;
    final detail = map['detail'];
    if (detail is! Map) return null;
    return TrajectoryRequestDetail.fromJson(detail.cast<String, dynamic>());
  }

  /// The wire dump stored in [path]; null when absent or corrupt.
  Future<TrajectoryWireDump?> readWireDump(String path) async {
    final map = await _readJson(path);
    if (map == null) return null;
    final dump = map['wireDump'];
    if (dump is! Map) return null;
    return TrajectoryWireDump.fromJson(dump.cast<String, dynamic>());
  }

  /// Enforces the rotation policy NOW: expired blobs go first (age past
  /// [ttlDays]), then oldest-by-mtime until the dir fits [maxBytes].
  /// Returns the deleted count; every failure is swallowed (rotation is
  /// hygiene, never a correctness path).
  Future<int> enforceBudget() async {
    final sid = _sessionId();
    final dir = trajectoryRequestBlobDir(sid);
    final listing = await _env.listDir(dir);
    final files = listing.valueOrNull ?? const <FileInfo>[];
    if (files.isEmpty) return 0;
    final now = _clock();
    final ttl = Duration(days: ttlDays);
    final sorted = [...files]..sort((a, b) => a.mtimeMs.compareTo(b.mtimeMs));
    var total = sorted.fold<int>(0, (sum, f) => sum + f.size);
    var deleted = 0;
    // Oldest first, and the NEWEST blob always survives — "keep last N"
    // semantics: expired files go regardless of the budget, beyond that
    // only the oldest files leave until the dir fits.
    for (var i = 0; i < sorted.length - 1; i++) {
      final file = sorted[i];
      final expired =
          now.difference(DateTime.fromMillisecondsSinceEpoch(file.mtimeMs)) >
          ttl;
      if (!expired && total <= maxBytes) break;
      await _env.remove(file.path, force: true);
      total -= file.size;
      deleted++;
    }
    return deleted;
  }

  /// Sweeps when a write crossed the byte budget or a sweep hour has
  /// elapsed (the TTL must advance even in sessions that never reach the
  /// budget).
  Future<void> _maybeSweep(int payloadBytes) async {
    _bytesSinceSweep += payloadBytes;
    final last = _lastSweepAt;
    final hourElapsed =
        last == null || _clock().difference(last) >= const Duration(hours: 1);
    if (_bytesSinceSweep < maxBytes && !hourElapsed) return;
    _bytesSinceSweep = 0;
    _lastSweepAt = _clock();
    await enforceBudget();
  }

  /// The boot-time TTL sweep (gh-1745 review): [enforceBudget] advances
  /// only while a session keeps receiving requests, so an ENDED session's
  /// blobs would age forever — the disk-footprint tail the ticket
  /// complains about survives at the directory level. Runs at most once
  /// per store instance (the store is built lazily at the first request
  /// of a session, which is the host's "session open"); best-effort.
  Future<void> sweepOncePerBoot() async {
    if (_bootSwept) return;
    _bootSwept = true;
    await sweepExpiredEverywhere();
  }

  /// Deletes every blob past [ttlDays] in EVERY session's request dir
  /// under `.fah/trajectories/`. Unlike [enforceBudget] there is no
  /// newest-kept grace: a dead session keeps nothing past the TTL.
  /// Returns the deleted count; every failure is swallowed (hygiene,
  /// never a correctness path).
  Future<int> sweepExpiredEverywhere() async {
    final root = await _env.listDir(trajectoryRequestBlobsRoot);
    final entries = root.valueOrNull ?? const <FileInfo>[];
    var deleted = 0;
    for (final entry in entries) {
      if (entry.kind != FileKind.directory) continue;
      deleted += await _sweepExpiredIn(
        '$trajectoryRequestBlobsRoot/${entry.name}/requests',
      );
    }
    return deleted;
  }

  /// The TTL-only pass over one explicit request-blob dir.
  Future<int> _sweepExpiredIn(String dir) async {
    final listing = await _env.listDir(dir);
    final files = listing.valueOrNull;
    if (files == null || files.isEmpty) return 0;
    final now = _clock();
    final ttl = Duration(days: ttlDays);
    var deleted = 0;
    for (final file in files) {
      final expired =
          now.difference(DateTime.fromMillisecondsSinceEpoch(file.mtimeMs)) >
          ttl;
      if (!expired) continue;
      final removed = await _env.remove(file.path, force: true);
      if (removed.isOk) deleted++;
    }
    return deleted;
  }

  Future<int> _maxExistingSequence(String? sid) async {
    final listing = await _env.listDir(trajectoryRequestBlobDir(sid));
    var max = 0;
    for (final file in listing.valueOrNull ?? const <FileInfo>[]) {
      final stem = file.name.endsWith('.json')
          ? file.name.substring(0, file.name.length - 5)
          : '';
      final value = int.tryParse(stem);
      if (value != null && value > max) max = value;
    }
    return max;
  }

  Future<Map<String, dynamic>?> _readJson(String path) async {
    final read = await _env.readTextFile(path);
    final text = read.valueOrNull;
    if (text == null) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } on Object {
      // Torn/corrupt blob: the reader degrades, never crashes.
    }
    return null;
  }
}
