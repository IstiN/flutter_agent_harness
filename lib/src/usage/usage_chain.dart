/// The chain half of the usage fold (gh-1241): walking a session's JSONL
/// record chain — the source of truth — into per-segment [FoldRequest]
/// lists, then into a [UsageLedger].
///
/// The scanner reads RAW lines, not typed records: it needs only a handful
/// of fields per record, and the chain's giant ledger-only payloads
/// (`model_request_summary`, blob tables) must not pay full
/// materialization. Known-irrelevant blob records (`trajectory_prompt_blob`
/// /`trajectory_manifest_blob`/`trajectory_wire_dump`) are skipped by
/// substring without `jsonDecode` — they can be megabytes of base64 and
/// contribute nothing to token sums.
///
/// Segment boundaries are `usage_segment_start` custom records appended by
/// the host at every session start/resume; a chain without any markers
/// folds as ONE segment (old sessions still produce a sane ledger).
/// Segment order is chain sequence (E4) — record timestamps land in the
/// artifact as informational `openedAt`/`closedAt` only.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../compaction/token_estimation.dart' show estimateTokens;
import '../context.dart' show messageFromJson;
import 'usage_fold.dart';
import 'usage_ledger.dart';

/// The custom record type that opens a usage segment (gh-1241 I1): appended
/// by the host at every session start/resume, consumed by
/// [UsageChainScanner] as the segment boundary.
const String usageSegmentStartCustomType = 'usage_segment_start';

/// The `model_request_summary` custom record type (trajectory ledger).
const String modelRequestSummaryCustomType = 'model_request_summary';

/// byModel key for requests whose model is unknown (errored requests that
/// never produced an assistant message, and their zero-filled fallbacks).
const String unknownUsageModel = 'unknown';

/// Chars-per-token of the shared chars/4 estimation heuristic
/// (`estimateTokens` in `token_estimation.dart`) — the fold's estimated
/// fallback prices input at the SAME rate the compaction estimator uses,
/// so an estimated request prices like the same request priced by the ctx
/// meter.
const int usageCharsPerToken = 4;

/// Custom-record types the scanner skips without decoding (megabyte-wide
/// ledger payloads irrelevant to token sums).
const _skipDecodeCustomTypes = [
  'trajectory_prompt_blob',
  'trajectory_manifest_blob',
  'trajectory_wire_dump',
];

/// One segment's raw fold input: the requests in chain order plus the
/// boundary timestamps derived from chain records.
final class UsageChainSegment {
  /// Creates a [UsageChainSegment].
  const UsageChainSegment({
    required this.requests,
    this.model,
    this.openedAt,
    this.closedAt,
  });

  /// The segment's provider requests.
  final List<FoldRequest> requests;

  /// The segment's LAST-SEEN model id (gh-1460): the model that served the
  /// final request — stamped into the `fa-tokens:` segment-close line so
  /// the row is attributable (and priceable) downstream. `null` when the
  /// segment never observed a model (legacy chains, zero-filled fallbacks
  /// only): the line then keeps its legacy shape.
  final String? model;

  /// First contributing record's chain timestamp (or the opening marker's).
  final DateTime? openedAt;

  /// Last contributing record's chain timestamp.
  final DateTime? closedAt;
}

/// The scan result: per-segment requests plus the chain fingerprint used
/// for stale/corrupt detection (E3) and idempotency (I6).
final class UsageChainScan {
  /// Creates a [UsageChainScan].
  const UsageChainScan({
    required this.segments,
    required this.recordCount,
    required this.chainHash,
  });

  /// Segments in chain order (always at least one).
  final List<UsageChainSegment> segments;

  /// Number of record lines consumed (header and torn lines excluded).
  final int recordCount;

  /// `sha256:`-prefixed fingerprint over the consumed raw record lines.
  final String chainHash;
}

/// Scans raw session-chain JSONL lines into [UsageChainScan].
final class UsageChainScanner {
  /// Creates a [UsageChainScanner].
  const UsageChainScanner();

  /// Scans [lines] (the session file's raw lines, header included).
  UsageChainScan scan(Iterable<String> lines) {
    final state = _ScanState();
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.isEmpty) continue;
      // Cheap pre-check for the giant blob records: hashed, counted, never
      // decoded.
      final skippedDecode = _isBlobRecord(line);
      final decoded = skippedDecode ? <String, dynamic>{} : _decode(line);
      if (decoded == null) continue; // torn line: contributes nothing
      final type = decoded['type'];
      if (type == 'session') continue; // header line
      state.noteRecord(line);
      if (skippedDecode) continue;
      final timestamp = DateTime.tryParse(
        decoded['timestamp'] as String? ?? '',
      );
      if (type == 'custom' &&
          decoded['customType'] == usageSegmentStartCustomType) {
        _handleMarker(timestamp, state);
        continue;
      }
      // Every other consumed record contributes its timestamp to the
      // current segment (its closedAt, or firstRecordAt fallback).
      state.current().noteRecordAt(timestamp);
      if (type == 'custom') {
        _handleSummary(decoded, state);
        continue;
      }
      if (type != 'message') continue;
      _handleAssistantMessage(decoded, state);
    }
    return state.finish();
  }

  /// Whether [line] carries one of the megabyte-wide ledger blob records
  /// the scanner skips without decoding.
  static bool _isBlobRecord(String line) {
    for (final blobType in _skipDecodeCustomTypes) {
      if (line.contains('"customType":"$blobType"')) return true;
    }
    return false;
  }

  /// Handles a segment-marker record. A marker OPENS the segment it
  /// introduces: the first marker on a chain claims the (lazy) first
  /// segment; a later marker closes the previous segment only when it
  /// carried anything (an empty trailing segment from a killed boot is
  /// not materialized, I1). The marker itself is not a "contributing"
  /// record: the previous segment's closedAt stays its last request's
  /// timestamp.
  void _handleMarker(DateTime? timestamp, _ScanState state) {
    if (!state.segments.lastOrNull.hasContentOrNull) {
      state.current().setOpenedAt(timestamp);
    } else {
      state.closeSegment(timestamp);
    }
  }

  /// Handles a `custom` record that is not a segment marker: a
  /// `model_request_summary` becomes the pending pair for the assistant
  /// message its request produces.
  void _handleSummary(Map<String, dynamic> decoded, _ScanState state) {
    if (decoded['customType'] == modelRequestSummaryCustomType) {
      state.pending = _PendingSummary.fromData(decoded['data']);
    }
  }

  /// Handles an assistant `message` record: only assistant messages
  /// produce a [FoldRequest], priced from the provider-reported usage or —
  /// when the provider omitted usage — estimated from the paired request
  /// summary.
  void _handleAssistantMessage(Map<String, dynamic> decoded, _ScanState state) {
    final message = decoded['message'];
    if (message is! Map || message['role'] != 'assistant') return;
    final request = _foldAssistant(
      message.cast<String, dynamic>(),
      state.pending,
    );
    state.current().addRequest(request);
    state.pending = null;
  }

  static Map<String, dynamic>? _decode(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } on Object {
      // Torn/foreign line: the tolerant reader skips it.
    }
    return null;
  }

  FoldRequest _foldAssistant(
    Map<String, dynamic> message,
    _PendingSummary? summary,
  ) {
    final model =
        (message['model'] as String?) ??
        (message['responseModel'] as String?) ??
        unknownUsageModel;
    final usage = message['usage'];
    final usageMap = usage is Map ? usage.cast<String, dynamic>() : null;
    final input = usageMap?['input'] as int? ?? 0;
    final output = usageMap?['output'] as int? ?? 0;
    final cacheRead = usageMap?['cacheRead'] as int? ?? 0;
    final cacheWrite = usageMap?['cacheWrite'] as int? ?? 0;
    final totalTokens = usageMap?['totalTokens'] as int? ?? 0;
    // Provider-reported iff any count is non-zero: AssistantMessage.usage
    // is non-nullable and providers that omit usage deserialize to
    // Usage.zero (AC4's fake-provider case).
    final reported =
        totalTokens > 0 ||
        input > 0 ||
        output > 0 ||
        cacheRead > 0 ||
        cacheWrite > 0;
    if (reported) {
      return FoldRequest(
        model: model,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite,
        reasoning: usageMap?['reasoning'] as int?,
        source: UsageSource.reported,
      );
    }
    // Estimated fallback (I3): input priced from the paired request
    // summary's outbound chars, output from the assistant payload's
    // chars — both at the shared chars/4 rate. Estimation failures degrade
    // to zero, never a crash.
    final inputChars = summary?.inputChars ?? 0;
    return FoldRequest(
      model: model,
      input: (inputChars / usageCharsPerToken).ceil(),
      output: _estimateAssistantOutput(message),
      source: UsageSource.estimated,
    );
  }

  int _estimateAssistantOutput(Map<String, dynamic> message) {
    try {
      return estimateTokens(messageFromJson(message));
    } on Object {
      return 0;
    }
  }
}

/// Mutable scan state: the segment list, the pending request summary, the
/// consumed-record fingerprint material, and the segment-close/finish
/// policy. Extracted from [UsageChainScanner.scan] so the per-record-type
/// handlers stay small enough for the CRAP ratchet.
final class _ScanState {
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  final List<_ScanSegment> segments = [];
  _PendingSummary? pending;
  var recordCount = 0;

  /// The current segment, creating the first lazily so a chain with no
  /// markers still folds as ONE segment.
  _ScanSegment current() {
    if (segments.isEmpty) segments.add(_ScanSegment());
    return segments.last;
  }

  /// Hashes and counts a consumed record line.
  void noteRecord(String line) {
    recordCount += 1;
    _bytes
      ..add(utf8.encode(line))
      ..add(const [10]);
  }

  /// A segment boundary: a summary whose request never produced an
  /// assistant message (provider error, abort) counts, with zero-fill
  /// marked estimated — never silently dropped (E1's "counts summed over
  /// what exists").
  void closeSegment(DateTime? boundaryAt) {
    if (pending case final summary?) {
      segments.last.requests.add(summary.fallback());
      pending = null;
    }
    segments.add(_ScanSegment()..setOpenedAt(boundaryAt));
  }

  /// Builds the scan result. A dangling summary still counts. A
  /// header-only chain still yields ONE (empty) segment so the ledger
  /// schema stays stable. A marker that closed a contentful segment
  /// opens a new one — when nothing followed it (the first drive after
  /// a resume errored before any request record landed), the empty
  /// trailing segment is trimmed, not materialized: otherwise
  /// resumedCount inflates (I1 noise) and the flush's fa-tokens line
  /// reports a zero-count segment labeled "reported".
  UsageChainScan finish() {
    if (pending case final summary?) {
      segments.lastOrNull?.requests.add(summary.fallback());
      pending = null;
    }
    if (segments.isEmpty) segments.add(_ScanSegment());
    while (segments.length > 1 && !segments.last.hasContent) {
      segments.removeLast();
    }
    return UsageChainScan(
      segments: [
        for (final segment in segments)
          UsageChainSegment(
            requests: segment.requests,
            model: segment.lastModel,
            openedAt: segment.openedAt ?? segment.firstRecordAt,
            closedAt: segment.closedAt,
          ),
      ],
      recordCount: recordCount,
      chainHash: 'sha256:${sha256.convert(_bytes.toBytes())}',
    );
  }
}

/// Mutable scan state for one segment.
final class _ScanSegment {
  _ScanSegment();

  DateTime? openedAt;
  final List<FoldRequest> requests = [];
  DateTime? firstRecordAt;
  DateTime? closedAt;

  /// The LAST-SEEN model on a real request (gh-1460): zero-filled fallbacks
  /// (`unknownUsageModel`) are not observations — they never overwrite a
  /// model the segment actually saw, and a segment of only fallbacks stays
  /// model-less so the segment-close line keeps its legacy shape.
  String? lastModel;

  /// Whether anything contributed to this segment (a marker claiming an
  /// empty virgin segment does not count — killed boots leave nothing).
  bool get hasContent => requests.isNotEmpty || firstRecordAt != null;

  /// Adds a request and, when it observed a real model, records it as the
  /// segment's last-seen model.
  void addRequest(FoldRequest request) {
    requests.add(request);
    if (request.model != unknownUsageModel) lastModel = request.model;
  }

  void setOpenedAt(DateTime? at) {
    openedAt ??= at;
  }

  void noteRecordAt(DateTime? at) {
    firstRecordAt ??= at;
    if (at != null) closedAt = at;
  }
}

/// Null-safe [ _ScanSegment.hasContent] probe for the boundary branch.
extension on _ScanSegment? {
  bool get hasContentOrNull => this?.hasContent ?? false;
}

/// A `model_request_summary` record waiting for the assistant message its
/// request produces (the summary always lands first on the chain).
final class _PendingSummary {
  _PendingSummary(this.inputChars);

  /// Σ `chars` of the summary's outbound request messages — the estimated
  /// input-token basis.
  final int inputChars;

  factory _PendingSummary.fromData(Object? data) {
    var chars = 0;
    if (data is Map) {
      final messages = data['messages'];
      if (messages is List) {
        for (final message in messages) {
          if (message is Map) {
            chars += message['chars'] as int? ?? 0;
          }
        }
      }
    }
    return _PendingSummary(chars);
  }

  /// The request never produced an assistant message: count it with
  /// zero-fill, marked estimated (E1).
  FoldRequest fallback() => const FoldRequest(
    model: unknownUsageModel,
    input: 0,
    output: 0,
    source: UsageSource.estimated,
  );
}

/// The rebuildable fold (gh-1241): records are the source of truth, so the
/// ledger is always recomputable from the chain — SIGKILL loses nothing
/// (AC3), running twice yields byte-identical output (I6).
final class UsageChainFolder {
  /// Creates a [UsageChainFolder].
  const UsageChainFolder({this.folder = const UsageFolder()});

  /// The pure fold math.
  final UsageFolder folder;

  /// Folds the session chain's raw [lines] into a [UsageLedger].
  UsageLedger foldChain({
    required String sessionId,
    required Iterable<String> lines,
    UsageChainScanner scanner = const UsageChainScanner(),
  }) {
    final scan = scanner.scan(lines);
    final segments = <UsageSegment>[
      for (var i = 0; i < scan.segments.length; i++)
        folder.foldSegment(
          i,
          scan.segments[i].requests,
          model: scan.segments[i].model,
          openedAt: scan.segments[i].openedAt,
          closedAt: scan.segments[i].closedAt,
        ),
    ];
    return UsageLedger(
      sessionId: sessionId,
      segments: segments,
      total: folder.totalOf(segments),
      chainRecords: scan.recordCount,
      chainHash: scan.chainHash,
    );
  }
}
