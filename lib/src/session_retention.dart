/// Session disk retention (gh-1746): an OPT-IN total-size cap over the
/// sessions root, enforced by an age-aware, live/named-safe sweep.
///
/// The framing guarantee: **with no `sessions.retention` config nothing is
/// EVER auto-deleted** — an absent section means byte-identical legacy
/// behavior (AC1). The config parses tolerantly (unknown keys and
/// mistyped scalars become notes, never boot failures), the usage walk is
/// O(directory entries) (stat-based sizes, never a byte-level read of
/// session files), and the sweep deletes oldest-last-used first while
/// exempting live sessions (presence), named sessions (`keepNamed`),
/// anything younger than `minAgeDays`, and the current session. A session
/// and its sidecars die together (`.tools/<id>.yaml`, the rotated
/// segments, the per-session usage directory, and the workspace
/// `.fah/spills/<id>/` spills).
///
/// Pure Dart over [FileSystem] (no `dart:io`) so every host (VM, app,
/// web) runs the same core; the CLI wires the real env and the boot log.
library;

import 'dart:convert';

import 'env/execution_env.dart';
import 'session/attach/session_presence.dart';
import 'session/session_chunk_reader.dart';
import 'session/session_record.dart' show SessionInfoRecord;
import 'session/session_storage.dart';

/// When the retention sweep runs (`sessions.retention.sweep`).
enum SessionRetentionSweepMode {
  /// Sweep at CLI boot (default).
  boot,

  /// Never sweep automatically — a set cap stays manual-only
  /// (`fa session clean`); boot only notes an over-cap total (E5).
  off,
}

/// The `sessions.retention:` block — the opt-in retention policy.
///
/// Defaults are the no-op policy: no cap (`maxTotalBytes: 0`), so nothing
/// is ever auto-deleted (AC1/AC2). Parsing is tolerant like
/// `SpillsConfig`: mistyped scalars fall back to the default with a note,
/// unknown keys are noted and ignored, and the parser never throws.
final class SessionRetentionConfig {
  /// Creates a configuration; see each field for its default.
  const SessionRetentionConfig({
    this.maxTotalBytes = 0,
    this.minAgeDays = defaultMinAgeDays,
    this.keepNamed = true,
    this.sweep = SessionRetentionSweepMode.boot,
    this.notes = const [],
  });

  /// The default `minAgeDays` (public for the yaml emitter's non-default
  /// check).
  static const int defaultMinAgeDays = 14;

  /// The total-size cap over the sessions root, in bytes. `0` (the
  /// default) means NO cap — nothing is ever auto-deleted.
  final int maxTotalBytes;

  /// A session last used more recently than this many days ago is never
  /// swept, no matter how far over the cap the root is (AC3).
  final int minAgeDays;

  /// Named sessions (`fa --session <name>`) are always exempt.
  final bool keepNamed;

  /// When the sweep runs (default [SessionRetentionSweepMode.boot]).
  final SessionRetentionSweepMode sweep;

  /// Tolerant-parse notes (unknown keys, mistyped scalars) surfaced at
  /// boot; never fatal.
  final List<String> notes;

  /// Whether a cap is configured — the master switch for every sweep.
  bool get hasCap => maxTotalBytes > 0;

  /// Whether any retention key differs from its default (a touched
  /// section). Drives the yaml emitter (defaults are never written).
  bool get hasExplicitValues =>
      maxTotalBytes != 0 ||
      minAgeDays != defaultMinAgeDays ||
      !keepNamed ||
      sweep != SessionRetentionSweepMode.boot;

  /// Parses the `retention:` map (the value of `sessions.retention:`).
  /// Tolerant: never throws; every deviation lands in [notes].
  factory SessionRetentionConfig.fromYaml(Object? node) {
    if (node == null) return const SessionRetentionConfig();
    if (node is! Map) {
      return const SessionRetentionConfig(
        notes: ['sessions.retention: not a map, defaults applied'],
      );
    }
    final notes = <String>[];
    var maxTotalBytes = 0;
    var minAgeDays = defaultMinAgeDays;
    var keepNamed = true;
    var sweep = SessionRetentionSweepMode.boot;
    node.forEach((key, value) {
      switch ('$key') {
        case 'maxTotalBytes':
          maxTotalBytes = _intWithNote(
            value,
            0,
            'sessions.retention.maxTotalBytes',
            notes,
          );
          if (maxTotalBytes < 0) {
            notes.add(
              'sessions.retention.maxTotalBytes: negative, clamped to 0 '
              '(no cap)',
            );
            maxTotalBytes = 0;
          }
        case 'minAgeDays':
          minAgeDays = _intWithNote(
            value,
            defaultMinAgeDays,
            'sessions.retention.minAgeDays',
            notes,
          );
          if (minAgeDays < 0) {
            notes.add('sessions.retention.minAgeDays: negative, clamped to 0');
            minAgeDays = 0;
          }
        case 'keepNamed':
          if (value is bool) {
            keepNamed = value;
          } else {
            notes.add(
              'sessions.retention.keepNamed: not a boolean, default applied',
            );
          }
        case 'sweep':
          final raw = '$value'.trim();
          final mode = switch (raw) {
            'boot' => SessionRetentionSweepMode.boot,
            'off' => SessionRetentionSweepMode.off,
            _ => null,
          };
          if (mode != null) {
            sweep = mode;
          } else {
            notes.add(
              'sessions.retention.sweep: "$raw" is not boot|off, '
              'default applied',
            );
          }
        default:
          notes.add('sessions.retention.$key: unknown key (ignored)');
      }
    });
    return SessionRetentionConfig(
      maxTotalBytes: maxTotalBytes,
      minAgeDays: minAgeDays,
      keepNamed: keepNamed,
      sweep: sweep,
      notes: List.unmodifiable(notes),
    );
  }

  static int _intWithNote(
    Object? value,
    int fallback,
    String name,
    List<String> notes,
  ) {
    if (value is int) return value;
    if (value is num) return value.round();
    notes.add('$name: not a number, default applied');
    return fallback;
  }

  /// The `retention:` block, only the non-default keys (the file stays
  /// minimal), indented [indent] spaces for nesting under `sessions:`.
  /// Empty at the defaults.
  String toYaml({int indent = 2}) {
    if (!hasExplicitValues) return '';
    final pad = ' ' * indent;
    final inner = ' ' * (indent + 2);
    final buffer = StringBuffer('${pad}retention:\n');
    if (maxTotalBytes != 0) {
      buffer.write('${inner}maxTotalBytes: $maxTotalBytes\n');
    }
    if (minAgeDays != defaultMinAgeDays) {
      buffer.write('${inner}minAgeDays: $minAgeDays\n');
    }
    if (!keepNamed) buffer.write('${inner}keepNamed: false\n');
    if (sweep != SessionRetentionSweepMode.boot) {
      final label = sweep == SessionRetentionSweepMode.off ? 'off' : 'boot';
      buffer.write('${inner}sweep: $label\n');
    }
    return buffer.toString();
  }
}

/// The `sessions:` config section (gh-1746). Today it carries only
/// [retention]; unknown members are noted, never fatal.
final class SessionsConfig {
  /// Creates a configuration; see [retention].
  const SessionsConfig({
    this.retention = const SessionRetentionConfig(),
    this.notes = const [],
  });

  /// The `retention:` block — defaults mean no retention at all.
  final SessionRetentionConfig retention;

  /// Tolerant-parse notes for the wrapper level (`sessions.<key>`).
  final List<String> notes;

  /// Whether the whole section is at its defaults (nothing persisted).
  bool get isEmpty => !retention.hasExplicitValues && notes.isEmpty;

  /// Parses the `sessions:` map. Tolerant: never throws.
  factory SessionsConfig.fromYaml(Object? node) {
    if (node == null) return const SessionsConfig();
    if (node is! Map) {
      return const SessionsConfig(
        notes: ['sessions: not a map, defaults applied'],
      );
    }
    final notes = <String>[];
    var retention = const SessionRetentionConfig();
    node.forEach((key, value) {
      switch ('$key') {
        case 'retention':
          retention = SessionRetentionConfig.fromYaml(value);
        default:
          notes.add('sessions.$key: unknown key (ignored)');
      }
    });
    return SessionsConfig(
      retention: retention,
      notes: List.unmodifiable(notes),
    );
  }

  /// The full `sessions:` section, only when non-default; empty at the
  /// defaults (the file stays minimal — defaults are never written).
  String toYaml() {
    if (retention.notes.isNotEmpty || notes.isNotEmpty) {
      // Notes mean hand-written content the typed renderer cannot
      // faithfully re-emit; stay silent and let the disk-preservation
      // backstop keep the raw block (the gh-1572 convention).
      return '';
    }
    if (!retention.hasExplicitValues) return '';
    return 'sessions:\n${retention.toYaml()}';
  }
}

/// The soft-visibility threshold (open question 1, posture B): with a
/// TOUCHED `sessions:` section but NO cap, a total above this emits one
/// boot NOTE (no action) suggesting the keys. A section-free config
/// stays byte-identical legacy (AC1) — no note ever.
const int retentionSoftWarnBytes = 5 * 1024 * 1024 * 1024;

/// One session's on-disk footprint — the sweep unit.
final class SessionDiskUsage {
  /// Creates the usage record.
  const SessionDiskUsage({
    required this.sessionId,
    required this.path,
    required this.bytes,
    required this.createdAt,
    required this.lastUsedAt,
    this.cwd,
    this.spillBytes = 0,
    this.name,
  });

  /// Session id (from the file basename; the header must parse for the
  /// file to be a candidate at all).
  final String sessionId;

  /// The primary transcript `.jsonl` path.
  final String path;

  /// Root-side unit bytes: the primary, its rotated `.part-NNNN` segments
  /// and `.corrupt` sidecars, `.tools/<sid>.yaml`, and the per-session
  /// usage directory. This is what the cap measures.
  final int bytes;

  /// Workspace-side spill bytes (`<cwd>/.fah/spills/<sid>/`) — freed with
  /// the session but NOT counted toward the cap (they live outside the
  /// sessions root).
  final int spillBytes;

  /// The session's recorded working directory (from the header) — the
  /// anchor for the workspace spills. Null when the header is unreadable.
  final String? cwd;

  /// When the session was created (from the header).
  final DateTime createdAt;

  /// Last used: the file mtime, floored at the header creation time (E3:
  /// a backup restore or clock skew can push mtime before createdAt).
  final DateTime lastUsedAt;

  /// The session's display name, when already known. Null = unresolved
  /// (the sweeper resolves lazily, only for deletion candidates).
  final String? name;

  /// Age in whole days as of [asOf].
  int ageDaysAt(DateTime asOf) => asOf.difference(lastUsedAt).inDays;
}

/// The stat-based usage walk result (O(directory entries), never O(file
/// bytes)).
final class SessionUsageSnapshot {
  /// Creates the snapshot.
  const SessionUsageSnapshot({
    required this.sessions,
    required this.totalBytes,
    this.notes = const [],
  });

  /// One entry per identifiable session file under the root.
  final List<SessionDiskUsage> sessions;

  /// Sum of the root-side unit bytes (what the cap measures).
  final int totalBytes;

  /// Walk anomalies (skipped symlinks, unreadable headers).
  final List<String> notes;

  /// No sessions (or no root).
  bool get isEmpty => sessions.isEmpty;
}

/// Why a session escaped the sweep.
enum SessionRetentionExemption {
  /// The session this process owns — never self-swept.
  current('current'),

  /// A fresh presence heartbeat exists — a running process owns it.
  live('live'),

  /// Last used inside `minAgeDays`.
  tooYoung('young'),

  /// Has a display name and `keepNamed` is true.
  named('named');

  const SessionRetentionExemption(this.label);

  /// Short reason label for plan/blocker lines.
  final String label;
}

/// One line of the sweep plan: either a planned/applied deletion or an
/// exempt blocker named by the loud over-cap note (AC4).
final class SessionSweepAction {
  /// Creates a plan entry.
  const SessionSweepAction({
    required this.sessionId,
    required this.path,
    required this.bytes,
    required this.ageDays,
    required this.exemption,
  });

  /// Session id.
  final String sessionId;

  /// Primary transcript path (the face of the unit in every line).
  final String path;

  /// Root-side unit bytes.
  final int bytes;

  /// Age in whole days at plan time.
  final int ageDays;

  /// Null for a deletion (reason: over-cap); the exemption otherwise.
  final SessionRetentionExemption? exemption;

  /// Whether this entry deletes.
  bool get isDeletion => exemption == null;
}

/// The outcome of one sweep (or plan — [dryRun] pins which).
final class SessionSweepReport {
  /// Creates the report.
  const SessionSweepReport({
    required this.dryRun,
    required this.capConfigured,
    required this.totalBytes,
    required this.capBytes,
    required this.actions,
    required this.rootFreedBytes,
    required this.spillFreedBytes,
    required this.logLines,
    this.notes = const [],
    this.overSoftWarn = false,
    this.overCapSweepOff = false,
    this.applied = false,
  });

  /// Whether this was a dry run (planned, nothing deleted).
  final bool dryRun;

  /// Whether a cap is configured at all.
  final bool capConfigured;

  /// Total root-side bytes at walk time.
  final int totalBytes;

  /// The configured cap (0 when none).
  final int capBytes;

  /// Deletions and blockers, in plan order (deletions oldest-first).
  final List<SessionSweepAction> actions;

  /// Root-side bytes freed (or that the plan WOULD free).
  final int rootFreedBytes;

  /// Workspace spill bytes freed (or planned to free).
  final int spillFreedBytes;

  /// Total freed bytes (root-side units + spills).
  int get freedBytes => rootFreedBytes + spillFreedBytes;

  /// Root-side bytes left after (or, in a dry run, hypothetically after)
  /// the deletions.
  int get remainingBytes => totalBytes - rootFreedBytes;

  /// The AC7 lines: one per deletion (and per mid-sweep skip). The host
  /// persists them to its boot log.
  final List<String> logLines;

  /// Walk/policy notes (symlinks skipped, presence failures, …).
  final List<String> notes;

  /// No cap configured and the total crosses [retentionSoftWarnBytes] —
  /// the boot caller may emit one hint note (posture B; never deletes).
  final bool overSoftWarn;

  /// A cap is configured but `sweep: off` and the total is over it —
  /// boot notes, the manual verb enforces (E5).
  final bool overCapSweepOff;

  /// Whether deletions were EXECUTED (false for dry runs and no-op
  /// policies).
  final bool applied;

  /// Sessions the plan deletes (or deleted).
  List<SessionSweepAction> get deletions =>
      actions.where((action) => action.isDeletion).toList();

  /// Exempt sessions named by the loud over-cap note (largest first).
  List<SessionSweepAction> get blockers =>
      actions.where((action) => !action.isDeletion).toList();

  /// Whether the exempt set alone kept the root over the cap (AC4) —
  /// the loud note names each blocker.
  bool get hasBlockerOverflow =>
      capConfigured && remainingBytes > capBytes && blockers.isNotEmpty;
}

SessionSweepReport _noOpReport({
  required SessionUsageSnapshot usage,
  required bool dryRun,
  required bool capConfigured,
  int capBytes = 0,
  List<String> notes = const [],
  bool overSoftWarn = false,
  bool overCapSweepOff = false,
}) => SessionSweepReport(
  dryRun: dryRun,
  capConfigured: capConfigured,
  totalBytes: usage.totalBytes,
  capBytes: capBytes,
  actions: const [],
  rootFreedBytes: 0,
  spillFreedBytes: 0,
  logLines: const [],
  notes: [...usage.notes, ...notes],
  overSoftWarn: overSoftWarn,
  overCapSweepOff: overCapSweepOff,
);

/// The opt-in session retention sweeper (gh-1746).
///
/// Pure Dart over [FileSystem]: walks the sessions root stat-first, plans
/// oldest-last-used-first deletions under the cap, and (on apply) deletes
/// whole units — the transcript, its rotated segments, the `.tools` scope
/// file, the per-session usage directory, and the workspace spills —
/// re-checking presence immediately before every unlink (E2).
final class SessionRetentionSweeper {
  // The sweeper's filesystem/root params read better under their public
  // names than as `_fs`/`_root` initializing formals (the repo's
  // established ignore, see checkpoint_tool.dart).
  // ignore_for_file: prefer_initializing_formals

  /// Creates a sweeper over [fs] rooted at [sessionsRoot].
  SessionRetentionSweeper({
    required FileSystem fs,
    required String sessionsRoot,
    this.retention = const SessionRetentionConfig(),
    this.presenceStore,
    this.currentSessionId,
    DateTime Function()? now,
    this.log,
    this.cleanWorkspaceSpills = true,
    this.softWarnBytes = retentionSoftWarnBytes,
  }) : _fs = fs,
       _root = sessionsRoot,
       _now = now ?? DateTime.now;

  /// The filesystem abstraction (never `dart:io`).
  final FileSystem _fs;

  /// The sessions root.
  final String _root;

  /// The opt-in policy; the default constructs to no cap at all.
  final SessionRetentionConfig retention;

  /// Live-session heartbeats; null disables the live exemption (tests
  /// without presence).
  final SessionPresenceStore? presenceStore;

  /// The session this process owns — never a deletion candidate.
  final String? currentSessionId;

  /// Clock seam (tests).
  final DateTime Function() _now;

  /// The AC7 sink: one line per deletion/skip. The host persists these
  /// to its boot log; null keeps the report-only behavior.
  final void Function(String line)? log;

  /// Whether the walk measures and apply removes the workspace
  /// `.fah/spills/<sid>/` dirs.
  final bool cleanWorkspaceSpills;

  /// The posture-B soft-warn threshold (seam: tests shrink it; prod uses
  /// [retentionSoftWarnBytes]).
  final int softWarnBytes;

  void _emit(String line) {
    log?.call(line);
  }

  Future<List<FileInfo>?> _listDirOrNull(String dir) async =>
      (await _fs.listDir(dir)).valueOrNull;

  /// The stat-based usage walk.
  Future<SessionUsageSnapshot> usage() async {
    final notes = <String>[];
    final exists = await _fs.exists(_root);
    if (!(exists.isOk && exists.valueOrNull == true)) {
      return const SessionUsageSnapshot(sessions: [], totalBytes: 0);
    }
    final topLevel = await _listDirOrNull(_root);
    if (topLevel == null) {
      notes.add('retention: sessions root unreadable: $_root');
      return SessionUsageSnapshot(sessions: const [], totalBytes: 0, notes: notes);
    }
    topLevel.sort((a, b) => a.name.compareTo(b.name));
    // Top-level dirs: `--slug--` workspace folders hold the transcripts;
    // every other non-dot dir may be a per-session usage directory
    // (`<root>/<sessionId>/usage.json`, gh-1241).
    final usageDirsByName = <String, FileInfo>{};
    final slugDirs = <FileInfo>[];
    for (final entry in topLevel) {
      if (entry.kind == FileKind.symlink) {
        notes.add('retention: skipped symlink ${entry.path} (E4)');
        continue;
      }
      if (entry.kind != FileKind.directory) continue;
      if (entry.name.startsWith('.')) continue; // .trash / .presence / …
      if (entry.name.startsWith('--') && entry.name.endsWith('--')) {
        slugDirs.add(entry);
      } else {
        usageDirsByName[entry.name] = entry;
      }
    }
    final sessions = <SessionDiskUsage>[];
    for (final slug in slugDirs) {
      sessions.addAll(await _scanSlugDir(slug, usageDirsByName, notes));
    }
    var total = 0;
    for (final session in sessions) {
      total += session.bytes;
    }
    return SessionUsageSnapshot(
      sessions: sessions,
      totalBytes: total,
      notes: List.unmodifiable(notes),
    );
  }

  Future<List<SessionDiskUsage>> _scanSlugDir(
    FileInfo slugDir,
    Map<String, FileInfo> usageDirsByName,
    List<String> notes,
  ) async {
    final children = await _listDirOrNull(slugDir.path);
    if (children == null) return const [];
    children.sort((a, b) => a.name.compareTo(b.name));
    final sessions = <SessionDiskUsage>[];
    for (final entry in children) {
      if (entry.kind == FileKind.symlink) {
        notes.add('retention: skipped symlink ${entry.path} (E4)');
        continue;
      }
      if (entry.kind != FileKind.file) continue;
      final sessionId = sessionIdFromSessionPath(entry.path);
      if (sessionId == null || !isSafePathSegment(sessionId)) continue;
      final header = await _headerFacts(entry.path);
      if (header == null) {
        // A file we cannot identify is never sweep food (only
        // positively-identified sessions are candidates).
        notes.add('retention: skipped unidentified ${entry.path}');
        continue;
      }
      final mtime = DateTime.fromMillisecondsSinceEpoch(entry.mtimeMs);
      // E3: last-used never precedes creation (backup tools touch mtimes
      // backwards; the header time is the floor).
      final lastUsed = mtime.isBefore(header.createdAt)
          ? header.createdAt
          : mtime;
      var bytes = entry.size;
      // The rotated segments and their `.corrupt` sidecars share the
      // unit: `<base>.part-NNNN` and `<base>[.part-NNNN].corrupt`.
      final baseName = entry.name;
      for (final sibling in children) {
        if (identical(sibling, entry)) continue;
        if (sibling.kind != FileKind.file) continue;
        final name = sibling.name;
        if (name.startsWith('$baseName.part-') || name == '$baseName.corrupt') {
          bytes += sibling.size;
        }
      }
      // The `.tools/<sid>.yaml` scope file dies with the session too.
      bytes += await _fileBytes('${slugDir.path}/.tools/$sessionId.yaml');
      // The per-session usage directory (`<root>/<sid>/usage.json`).
      final usageDir = usageDirsByName[sessionId];
      if (usageDir != null) {
        bytes += await _dirBytes(usageDir.path, notes);
      }
      // Workspace spills are freed with the session but live outside the
      // root — reported, never counted toward the cap.
      var spillBytes = 0;
      if (cleanWorkspaceSpills && header.cwd.isNotEmpty) {
        spillBytes = await _dirBytes(
          '${header.cwd}/.fah/spills/$sessionId',
          notes,
        );
      }
      sessions.add(
        SessionDiskUsage(
          sessionId: sessionId,
          path: entry.path,
          bytes: bytes,
          spillBytes: spillBytes,
          cwd: header.cwd,
          createdAt: header.createdAt,
          lastUsedAt: lastUsed,
        ),
      );
    }
    return sessions;
  }

  Future<int> _fileBytes(String path) async {
    final info = (await _fs.fileInfo(path)).valueOrNull;
    return info != null && info.kind == FileKind.file ? info.size : 0;
  }

  /// Recursive byte sum of [dir]; symlinks are skipped, never followed
  /// out of the root (E4).
  Future<int> _dirBytes(String dir, List<String> notes) async {
    final children = await _listDirOrNull(dir);
    if (children == null) return 0;
    var total = 0;
    for (final entry in children) {
      if (entry.kind == FileKind.symlink) {
        notes.add('retention: skipped symlink ${entry.path} (E4)');
        continue;
      }
      if (entry.kind == FileKind.directory) {
        total += await _dirBytes(entry.path, notes);
      } else {
        total += entry.size;
      }
    }
    return total;
  }

  Future<_SessionHeaderFacts?> _headerFacts(String path) async {
    final lines = (await _fs.readTextLines(path, maxLines: 1)).valueOrNull;
    final line = (lines == null || lines.isEmpty) ? null : lines.first;
    if (line == null || line.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on Object {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final id = decoded['id'];
    final cwd = decoded['cwd'];
    final timestamp = decoded['timestamp'];
    if (id is! String || cwd is! String || timestamp is! String) return null;
    final createdAt = DateTime.tryParse(timestamp);
    if (createdAt == null) return null;
    return _SessionHeaderFacts(id: id, cwd: cwd, createdAt: createdAt);
  }

  /// Fresh presence ids; null means "presence unavailable" — the sweep
  /// FAILS CLOSED (no deletions) rather than risk a live session (AC3).
  Future<Set<String>?> _liveIds() async {
    final store = presenceStore;
    if (store == null) return const {};
    try {
      return (await store.list()).keys.toSet();
    } on Object {
      return null;
    }
  }

  /// The display name of [session] via the bounded head/tail probes the
  /// picker already uses — resolved lazily, only for deletion candidates.
  Future<String?> _nameOf(SessionDiskUsage session) async {
    final segments = await listSessionSegmentPaths(_fs, session.path);
    for (final segment in segments.reversed) {
      SessionInfoRecord? info;
      try {
        info = await SessionChunkReader(
          fs: _fs,
          path: segment,
        ).readNewestSessionInfo();
      } on Object {
        if (segment == session.path) return null;
        continue; // an unreadable part must not kill name resolution
      }
      if (info == null) continue;
      final trimmed = info.name?.trim();
      if (trimmed == null || trimmed.isEmpty) continue;
      return trimmed;
    }
    return null;
  }

  /// The boot policy (E5 + posture B): no cap → a soft-warn-only report;
  /// cap + `sweep: off` → over-cap note, no deletions; cap + boot → the
  /// full sweep.
  Future<SessionSweepReport> enforceAtBoot() async {
    final current = await usage();
    if (!retention.hasCap) {
      return _noOpReport(
        usage: current,
        dryRun: true,
        capConfigured: false,
        overSoftWarn: current.totalBytes > softWarnBytes,
      );
    }
    if (retention.sweep == SessionRetentionSweepMode.off) {
      return _noOpReport(
        usage: current,
        dryRun: true,
        capConfigured: true,
        capBytes: retention.maxTotalBytes,
        overCapSweepOff: current.totalBytes > retention.maxTotalBytes,
      );
    }
    return sweep(dryRun: false, prebuilt: current);
  }

  /// Plans the sweep (and applies it when [dryRun] is false).
  Future<SessionSweepReport> sweep({
    required bool dryRun,
    SessionUsageSnapshot? prebuilt,
  }) async {
    final usage = prebuilt ?? await this.usage();
    if (!retention.hasCap) {
      return _noOpReport(usage: usage, dryRun: dryRun, capConfigured: false);
    }
    final cap = retention.maxTotalBytes;
    if (usage.totalBytes <= cap) {
      // AC2: under the cap — no deletions, no noise.
      return _noOpReport(
        usage: usage,
        dryRun: dryRun,
        capConfigured: true,
        capBytes: cap,
      );
    }
    // Presence first, fail-closed: an unavailable probe aborts the sweep
    // instead of risking a live session (AC3).
    final live = await _liveIds();
    if (live == null) {
      return _noOpReport(
        usage: usage,
        dryRun: dryRun,
        capConfigured: true,
        capBytes: cap,
        notes: ['retention: presence probe failed — sweep aborted'],
      );
    }
    final now = _now();
    final cutoff = now.subtract(Duration(days: retention.minAgeDays));
    final deletable =
        usage.sessions.where((session) {
          if (session.sessionId == currentSessionId) return false;
          if (live.contains(session.sessionId)) return false;
          if (!session.lastUsedAt.isBefore(cutoff)) return false;
          return true;
        }).toList()
          ..sort((a, b) {
            final byLastUsed = a.lastUsedAt.compareTo(b.lastUsedAt);
            if (byLastUsed != 0) return byLastUsed;
            final byCreated = a.createdAt.compareTo(b.createdAt);
            if (byCreated != 0) return byCreated;
            return a.path.compareTo(b.path);
          });
    final deletions = <SessionSweepAction>[];
    final namedBlockerIds = <String>{};
    var freed = 0;
    var spillFreed = 0;
    for (final session in deletable) {
      if (usage.totalBytes - freed <= cap) break;
      if (retention.keepNamed) {
        final name = session.name ?? await _nameOf(session);
        if (name != null && name.isNotEmpty) {
          namedBlockerIds.add(session.sessionId);
          continue;
        }
      }
      deletions.add(_action(session, now, null));
      freed += session.bytes;
      spillFreed += session.spillBytes;
    }
    final logLines = <String>[];
    var applied = false;
    if (!dryRun && deletions.isNotEmpty) {
      applied = true;
      for (final action in deletions) {
        // E2: the presence check happens immediately before each unlink —
        // a session that became live mid-sweep is skipped, never forced.
        final fresh = await _liveIds();
        if (fresh == null || fresh.contains(action.sessionId)) {
          final skip =
              'retention: skipped ${action.path} (became live mid-sweep)';
          logLines.add(skip);
          _emit(skip);
          freed -= action.bytes;
          spillFreed -= _spillBytesOf(usage, action.sessionId);
          continue;
        }
        await _deleteUnit(usage, action);
        final line =
            'retention: deleted ${action.path} '
            '(${formatRetentionBytes(action.bytes)}; age ${action.ageDays}d; '
            'over-cap)';
        logLines.add(line);
        _emit(line);
      }
    }
    // AC4: when the deletable set cannot bring the root under the cap,
    // name every exempt blocker (largest first) — never force.
    final remaining = usage.totalBytes - freed;
    final blockers = <SessionSweepAction>[];
    if (remaining > cap) {
      final deletedIds = deletions.map((a) => a.sessionId).toSet();
      for (final session in usage.sessions) {
        if (deletedIds.contains(session.sessionId)) continue;
        blockers.add(
          _action(
            session,
            now,
            _exemptionOf(session, live, namedBlockerIds),
          ),
        );
      }
      blockers.sort((a, b) => b.bytes.compareTo(a.bytes));
      final held = blockers.fold<int>(0, (sum, b) => sum + b.bytes);
      final note =
          'retention: still over cap by '
          '${formatRetentionBytes(remaining - cap)} — ${blockers.length} '
          'exempt session(s) hold ${formatRetentionBytes(held)}; '
          'nothing else is deletable';
      logLines.add(note);
      _emit(note);
    }
    return SessionSweepReport(
      dryRun: dryRun,
      capConfigured: true,
      totalBytes: usage.totalBytes,
      capBytes: cap,
      actions: [...deletions, ...blockers],
      rootFreedBytes: freed,
      spillFreedBytes: spillFreed,
      logLines: List.unmodifiable(logLines),
      notes: usage.notes,
      applied: applied,
    );
  }

  int _spillBytesOf(SessionUsageSnapshot usage, String sessionId) {
    for (final session in usage.sessions) {
      if (session.sessionId == sessionId) return session.spillBytes;
    }
    return 0;
  }

  SessionSweepAction _action(
    SessionDiskUsage session,
    DateTime now,
    SessionRetentionExemption? exemption,
  ) => SessionSweepAction(
    sessionId: session.sessionId,
    path: session.path,
    bytes: session.bytes,
    ageDays: session.ageDaysAt(now),
    exemption: exemption,
  );

  SessionRetentionExemption _exemptionOf(
    SessionDiskUsage session,
    Set<String> live,
    Set<String> namedBlockerIds,
  ) {
    if (session.sessionId == currentSessionId) {
      return SessionRetentionExemption.current;
    }
    if (live.contains(session.sessionId)) return SessionRetentionExemption.live;
    if (namedBlockerIds.contains(session.sessionId)) {
      return SessionRetentionExemption.named;
    }
    return SessionRetentionExemption.tooYoung;
  }

  /// Deletes one whole sweep unit. Every remove is force — a vanished
  /// sidecar is fine; a partially-deleted unit is still a deletion.
  Future<void> _deleteUnit(
    SessionUsageSnapshot usage,
    SessionSweepAction action,
  ) async {
    SessionDiskUsage? session;
    for (final candidate in usage.sessions) {
      if (candidate.sessionId == action.sessionId) {
        session = candidate;
        break;
      }
    }
    if (session == null) return;
    final path = session.path;
    final separatorIndex = path.lastIndexOf('/');
    final dir = separatorIndex <= 0 ? null : path.substring(0, separatorIndex);
    final baseName = path.split('/').last;
    // Primary + rotated segments + corrupt sidecars.
    final children = (await _listDirOrNull(dir ?? '')) ?? const <FileInfo>[];
    for (final child in children) {
      if (child.kind != FileKind.file) continue;
      if (child.name == baseName ||
          child.name.startsWith('$baseName.part-') ||
          child.name == '$baseName.corrupt') {
        await _fs.remove(child.path, force: true);
      }
    }
    // `.tools/<sid>.yaml` and the per-session usage dir `<root>/<sid>/`.
    if (isSafePathSegment(session.sessionId)) {
      if (dir != null) {
        await _fs.remove('$dir/.tools/${session.sessionId}.yaml', force: true);
      }
      await _removeTree('$_root/${session.sessionId}');
      // Workspace spills `<cwd>/.fah/spills/<sid>/`.
      final cwd = session.cwd;
      if (cleanWorkspaceSpills && cwd != null && cwd.isNotEmpty) {
        await _removeTree('$cwd/.fah/spills/${session.sessionId}');
      }
    }
  }

  /// Removes a directory tree unless it is a symlink (E4: never follow
  /// links out of the root).
  Future<void> _removeTree(String dir) async {
    final info = (await _fs.fileInfo(dir)).valueOrNull;
    if (info == null) return; // nothing there
    if (info.kind == FileKind.symlink) return;
    await _fs.remove(dir, recursive: true, force: true);
  }
}

/// The session id encoded in a session file basename
/// (`<timestamp>_<sessionId>.jsonl`); null when the name has no id part
/// (foreign files are never sweep candidates).
String? sessionIdFromSessionPath(String path) {
  final base = path.split(RegExp(r'[/\\]')).last;
  if (!base.endsWith('.jsonl')) return null;
  final parts = base.substring(0, base.length - '.jsonl'.length).split('_');
  return parts.length < 2 || parts.last.isEmpty ? null : parts.last;
}

/// Whether [segment] can be safely joined under a trusted directory:
/// rejects path separators and `.`/`..` (E4 path-escape guard).
bool isSafePathSegment(String segment) =>
    segment.isNotEmpty &&
    segment != '.' &&
    segment != '..' &&
    !segment.contains('/') &&
    !segment.contains(r'\');

final class _SessionHeaderFacts {
  const _SessionHeaderFacts({
    required this.id,
    required this.cwd,
    required this.createdAt,
  });

  final String id;
  final String cwd;
  final DateTime createdAt;
}

/// Human-readable bytes for footer/plan/log lines (`4.9 GB`, `512 KB`,
/// `37 B`) — 1024-based, one decimal below ten.
String formatRetentionBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 100 || value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// Renders [report] as the `fa session clean` output lines (the exact
/// plan for a dry run, the applied outcome otherwise; AC6). Empty for a
/// silent no-cap report below the soft-warn threshold.
List<String> sessionSweepReportLines(SessionSweepReport report) {
  final lines = <String>[];
  if (!report.capConfigured) {
    if (report.overSoftWarn) {
      lines.add(
        'sessions: ${formatRetentionBytes(report.totalBytes)} on disk — no '
        'sessions.retention cap configured; set '
        'sessions.retention.maxTotalBytes in ~/.fah/config.yaml to enable '
        'a sweep',
      );
    }
    return lines;
  }
  final mode = report.dryRun
      ? 'dry run — nothing deleted'
      : (report.applied ? 'applied' : 'nothing to delete');
  lines.add(
    'sessions clean: $mode (cap ${formatRetentionBytes(report.capBytes)}, '
    'total ${formatRetentionBytes(report.totalBytes)})',
  );
  for (final action in report.deletions) {
    lines.add(
      '${report.applied ? 'deleted' : 'would delete'}: ${action.path} '
      '(${formatRetentionBytes(action.bytes)}; age ${action.ageDays}d; '
      'over-cap)',
    );
  }
  if (report.freedBytes > 0) {
    lines.add(
      'freed: ${formatRetentionBytes(report.freedBytes)} · '
      'remaining: ${formatRetentionBytes(report.remainingBytes)}',
    );
  }
  if (report.overCapSweepOff) {
    lines.add(
      'sessions over cap (${formatRetentionBytes(report.totalBytes)} > '
      '${formatRetentionBytes(report.capBytes)}) and retention sweep is off; '
      'run fa session clean to enforce it',
    );
  }
  if (report.hasBlockerOverflow) {
    lines.add('exempt sessions keep the root over the cap:');
    for (final blocker in report.blockers) {
      lines.add(
        '  - ${blocker.path} (${formatRetentionBytes(blocker.bytes)}, '
        '${blocker.exemption!.label})',
      );
    }
  }
  for (final note in report.notes) {
    lines.add(note);
  }
  return lines;
}
