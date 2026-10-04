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
    this.openedAt,
    this.closedAt,
  });

  /// The segment's provider requests.
  final List<FoldRequest> requests;

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
    final bytes = BytesBuilder(copy: false);
    var recordCount = 0;
    final segments = <_ScanSegment>[_ScanSegment()];
    _PendingSummary? pending;
    void closeSegment(DateTime? boundaryAt) {
      if (pending case final summary?) {
        // A summary whose request never produced an assistant message
        // (provider error, abort): the request counts, with zero-fill
        // marked estimated — never silently dropped (E1's "counts summed
        // over what exists").
        segments.last.requests.add(summary.fallback());
        pending = null;
      }
      segments.add(_ScanSegment(openedAt: boundaryAt));
    }

    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.isEmpty) continue;
      // Cheap pre-check for the giant blob records: hashed, counted, never
      // decoded.
      var skippedDecode = false;
      for (final type in _skipDecodeCustomTypes) {
        if (line.contains('"customType":"$type"')) {
          skippedDecode = true;
          break;
        }
      }
      final decoded = skippedDecode ? <String, dynamic>{} : _decode(line);
      if (decoded == null) continue; // torn line: contributes nothing
      final type = decoded['type'];
      if (type == 'session') continue; // header line
      recordCount += 1;
      bytes
        ..add(utf8.encode(line))
        ..add(const [10]);
      if (skippedDecode) continue;
      final timestamp = DateTime.tryParse(decoded['timestamp'] as String? ?? '');
      final current = segments.last;
      current.noteRecordAt(timestamp);
      if (type == 'custom') {
        final customType = decoded['customType'] as String? ?? '';
        if (customType == usageSegmentStartCustomType) {
          closeSegment(timestamp);
        } else if (customType == modelRequestSummaryCustomType) {
          pending = _PendingSummary.fromData(decoded['data']);
        }
        continue;
      }
      if (type != 'message') continue;
      final message = decoded['message'];
      if (message is! Map || message['role'] != 'assistant') continue;
      final request = _foldAssistant(
        message.cast<String, dynamic>(),
        pending,
      );
      pending = null;
      current.requests.add(request);
    }
    // Close the trailing segment: a dangling summary still counts.
    if (pending case final summary?) {
      segments.last.requests.add(summary.fallback());
      pending = null;
    }
    return UsageChainScan(
      segments: [
        for (final segment in segments)
          UsageChainSegment(
            requests: segment.requests,
            openedAt: segment.openedAt ?? segment.firstRecordAt,
            closedAt: segment.closedAt,
          ),
      ],
      recordCount: recordCount,
      chainHash: 'sha256:${sha256.convert(bytes.toBytes())}',
    );
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

/// Mutable scan state for one segment.
final class _ScanSegment {
  _ScanSegment({this.openedAt});

  final List<FoldRequest> requests = [];
  final DateTime? openedAt;
  DateTime? firstRecordAt;
  DateTime? closedAt;

  void noteRecordAt(DateTime? at) {
    firstRecordAt ??= at;
    if (at != null) closedAt = at;
  }
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
