/// The durable subagent deliverable path (issue #1829): deliverable
/// capture, the redacting artifact writer, and the deliverable envelope.
///
/// A child report can be lost twice: generation-side output truncation
/// discards the `reply` payload, and delivery-side capping reduces a
/// successful payload to a head fragment. This module makes the
/// child-to-parent deliverable path size-safe:
///
/// - **Core flow A** — a successful over-cap `reply` / same-session
///   `agent_message` body is redacted, persisted to the child's existing
///   `AgentOutputStore`, and delivered as a bounded envelope (head excerpt
///   + `agent://` pointer + explicit completeness status) instead of the
///   bare head fragment.
/// - **Core flow B** — an output-truncated deliverable call is NEVER
///   executed (the fail-closed boundary in the agent loop is unchanged);
///   its salvage-parsed text is captured as a `partial` artifact and the
///   pointer rides the child completion/task result out of band.
/// - **Core flow C** — the chunk contract ([deliverableChunkContract])
///   published through the tool descriptions and child system prompt:
///   ordered `agent_message` parts + a final short `reply` manifest, with
///   the harness tracking observed parts and ruling on manifest
///   completeness (a child-authored "complete" label is not authoritative).
///
/// Invariants: deliverable TEXT only (never executable tool arguments —
/// I1); redaction runs before persistence (I3); `complete` / `partial` /
/// `artifact-unavailable` stay distinct (I4); the stored artifact is
/// exactly the redacted text — no repair (I5); same-session pointers only
/// (I6/E11).
library;

import 'dart:async';
import 'dart:convert';

import '../prompts/prompts.g.dart'
    show taskReportSizeContractPrompt, taskPureChunkContractPrompt;
import '../types.dart' show ToolCall;
import 'output_manager.dart';
import 'subagent_manager.dart';

// The public named parameter maps to a private field; an initializing formal
// would make the parameter name private and unusable outside this library.
// ignore_for_file: prefer_initializing_formals

/// Tool names whose text payload the durable deliverable path captures.
/// The allowlist is the I1 boundary: no other tool's arguments are ever
/// inspected, persisted, or delivered by this path.
const Set<String> deliverableToolNames = {'reply', 'agent_message'};

/// The parent-session custom record type carrying one durable spilled
/// artifact per record (gh-1956, AC6): a resumed session re-seeds its
/// store from these rows, so an `agent://` pointer survives restart.
const String deliverableArtifactRecordType = 'deliverable_artifact';

/// What a recorded deliverable is: a stored artifact (over-cap body or
/// salvaged partial text), an observed report chunk, or a final-manifest
/// verdict.
enum DeliverableRecordKind { artifact, chunk, manifest }

/// One recorded deliverable event on a child's handle (issue #1829).
/// Rendered onto the parent's task result so the recipient sees explicit
/// completeness and resolvable pointers.
final class DeliverableRecord {
  DeliverableRecord.artifact({
    required this.childId,
    required this.outputId,
    required this.status,
    this.reportId,
    this.partIndex,
    required this.chars,
    required this.bytes,
  }) : kind = DeliverableRecordKind.artifact,
       partCount = null,
       missingParts = const [],
       verdictNote = '',
       manifestVerdict = null;

  /// An observed report chunk (delivered directly or via artifact).
  DeliverableRecord.chunk({
    required this.childId,
    required this.reportId,
    required this.partIndex,
    this.outputId,
    required this.chars,
  }) : kind = DeliverableRecordKind.chunk,
       status = null,
       bytes = null,
       partCount = null,
       missingParts = const [],
       verdictNote = '',
       manifestVerdict = null;

  /// The verdict on a final report manifest: [manifestVerdict] is the
  /// HARNESS's ruling, never the child's label.
  DeliverableRecord.manifest({
    required this.childId,
    required this.reportId,
    required this.partCount,
    required bool complete,
    this.missingParts = const [],
    this.verdictNote = '',
    required this.chars,
  }) : kind = DeliverableRecordKind.manifest,
       status = null,
       outputId = null,
       partIndex = null,
       bytes = null,
       manifestVerdict = complete;

  final DeliverableRecordKind kind;

  /// The child that produced the deliverable.
  final String childId;

  /// Artifact completeness; null for chunk/manifest records.
  final AgentArtifactStatus? status;

  /// The `agent://` output id (artifacts, and oversize chunks). Null when
  /// the content was delivered directly with no artifact.
  final String? outputId;

  /// Child-selected report id, when the chunk/manifest protocol is in use.
  final String? reportId;

  /// Chunk part index (chunk records).
  final int? partIndex;

  /// Declared total part count (manifest records).
  final int? partCount;

  /// Parts of the manifest that were never observed (manifest records).
  final List<int> missingParts;

  /// Why a manifest was ruled incomplete, when not obvious from
  /// [missingParts] (duplicates, out-of-order arrivals, no declared count).
  final String verdictNote;

  /// The harness's completeness ruling for manifest records.
  final bool? manifestVerdict;

  /// Character count of the redacted artifact text (artifacts) or the raw
  /// chunk/manifest body.
  final int chars;

  /// UTF-8 byte count of the stored artifact text (artifacts only, gh-1956
  /// completeness marker); null for chunk/manifest records.
  final int? bytes;

  /// Whether a manifest record ruled the report complete (all declared
  /// parts observed, none duplicated, none out of order).
  bool get manifestComplete => manifestVerdict ?? false;

  /// The resolvable pointer, or null for direct deliveries.
  String? get pointer => outputId == null ? null : 'agent://$outputId';

  /// One parent-visible line.
  String render() => switch (kind) {
    DeliverableRecordKind.artifact => _renderArtifact(),
    DeliverableRecordKind.chunk => _renderChunk(),
    DeliverableRecordKind.manifest => _renderManifest(),
  };

  /// Per-part artifacts say "part N stored", never report-level
  /// "complete" — a parent skimming result lines must not read one
  /// stored part as "report complete" (review, issue #1829).
  String _renderArtifact() {
    if (partIndex != null) {
      return 'report ${reportId!} part ${partIndex!} stored '
          '(over budget): agent://$outputId '
          '($chars chars, $bytes bytes)';
    }
    return 'deliverable ${status!.name}'
        '${reportId == null ? '' : ' (report $reportId)'}: '
        'agent://$outputId ($chars chars, $bytes bytes)';
  }

  String _renderChunk() =>
      'report ${reportId!} part ${partIndex!}: '
      '${outputId == null ? 'delivered directly' : 'agent://$outputId'} '
      '($chars chars)';

  String _renderManifest() {
    if (manifestComplete) {
      return 'report ${reportId!} manifest: complete ($partCount parts)';
    }
    final line = StringBuffer('report ${reportId!} manifest: INCOMPLETE');
    if (verdictNote.isNotEmpty) {
      line.write(' — $verdictNote');
    }
    if (missingParts.isNotEmpty) {
      line.write('; missing parts $missingParts');
    }
    return line.toString();
  }
}

/// The harness-observed state of one child report's chunk set: arrival
/// order, duplicates, and which declared parts never showed up. Drives the
/// manifest verdict (Core flow C, E10): a child-authored "complete" label
/// cannot hide duplicate, missing, or out-of-order parts.
final class _ChunkLedger {
  final parts = <int>{};
  var duplicates = 0;
  var outOfOrder = 0;
  var nextExpected = 0;

  void observe(int partIndex) {
    if (!parts.add(partIndex)) {
      duplicates++;
      return;
    }
    if (partIndex != nextExpected) outOfOrder++;
    nextExpected = partIndex + 1;
  }

  /// Parts of `0..count-1` never observed.
  List<int> missingOf(int count) => [
    for (var i = 0; i < count; i++)
      if (!parts.contains(i)) i,
  ];
}

/// The child-side chunk contract published through the `reply` /
/// `agent_message` tool descriptions and the child system prompt (Core
/// flow C, AC5). [budget] is the live per-message character cap.
///
/// With auto-spill on (the default, gh-1956) the contract teaches the
/// automatic path — send one complete reply, the harness spills oversized
/// reports to an `agent://` artifact — and demotes manual chunking to the
/// fallback. With auto-spill off (`subagents.replyAutoSpill: false`) the
/// pure-chunk contract restores the manual protocol as the ONLY path.
///
/// The LM-facing text lives in `prompts/task/report_size_contract.md`
/// (spill on) and `prompts/task/pure_chunk_contract.md` (kill switch)
/// (AGENTS.md: prompts live outside Dart code; edits regenerate
/// `prompts.g.dart` and are drift-gated by `prompts_sync_test`). This
/// wrapper is the single substitution seam for the dynamic budget.
String deliverableChunkContract(int budget, {bool autoSpill = true}) =>
    (autoSpill ? taskReportSizeContractPrompt : taskPureChunkContractPrompt)
        .replaceAll('{{budget}}', '$budget');

/// Harness-owned capture + redacting artifact writer + envelope builder
/// for one session (issue #1829). Bound to the session's existing
/// [AgentOutputStore] and [SubagentManager] (the `maxReplyChars` budget);
/// wired by the task executor into the child tool surface and the agent
/// loop's truncated-call hook.
///
/// gh-1956 (reply auto-spill): the spill path is the DEFAULT delivery for
/// oversized reports — a child may call `reply` with whatever it has and
/// the harness persists + refers. [autoSpill] is the kill-switch getter
/// (`subagents.replyAutoSpill`; default on): when it returns false the
/// capture stops spilling and manual chunking degrades to the fallback
/// (pure-chunk behavior). [persistArtifact] / [restoreArtifacts] are the
/// durable-artifact seam: every spill appends one restorable row through
/// the sink (best-effort — a failed row never corrupts the in-session
/// delivery), and [ensureRestored] re-seeds a resumed session's store so
/// spilled artifacts survive parent resume and stay resolvable (AC6).
final class DeliverableCapture {
  /// Creates a capture. [redact] is the pre-persistence gate (I3) — the
  /// same redaction pipeline tool results pass; null means the host runs
  /// no redactor (identity, matching unredacted tool-result delivery).
  DeliverableCapture({
    required this.store,
    required this.manager,
    String Function(String text)? redact,
    bool Function()? autoSpill,
    Future<void> Function(Map<String, dynamic> artifact)? persistArtifact,
    Future<List<Map<String, dynamic>>> Function()? restoreArtifacts,
  }) : _redact = redact,
       _autoSpill = autoSpill,
       _persistArtifact = persistArtifact,
       _restoreArtifacts = restoreArtifacts;

  /// The session output store backing `agent://` resolution.
  final AgentOutputStore store;

  /// The retained-subagent manager owning the budget and the handles the
  /// records/pointers attach to.
  final SubagentManager manager;

  final String Function(String text)? _redact;

  /// The kill-switch getter (gh-1956): null or true = auto-spill on (the
  /// default); false = pure-chunk behavior restored.
  final bool Function()? _autoSpill;

  /// The durable-artifact sink: one append row per spill (best-effort).
  final Future<void> Function(Map<String, dynamic> artifact)? _persistArtifact;

  /// The durable-artifact source backing [ensureRestored] after a resume.
  final Future<List<Map<String, dynamic>>> Function()? _restoreArtifacts;

  /// Whether oversized replies auto-spill (the default path, gh-1956).
  bool get spillEnabled => _autoSpill?.call() ?? true;

  /// Whether [target] is a recipient an `agent://` spill pointer can
  /// reach (a same-session handle or the parent inbox) — the E11 gate
  /// the tools reuse to shape their fallback notices.
  bool spillApliesTo(String target) => _isSameSession(target);

  /// Memoized restore (AC6): re-seeds the store from the durable rows
  /// BEFORE the first spill or tool-driven delivery, so a resumed
  /// session's ids stay reserved (a new spill can never clobber a
  /// restored artifact). Idempotent; a failed source degrades to an
  /// empty restore without breaking the capture.
  Future<void>? _restoreFuture;

  Future<void> ensureRestored() {
    final source = _restoreArtifacts;
    return _restoreFuture ??= source == null
        ? Future<void>.value()
        : _runRestore(source);
  }

  Future<void> _runRestore(
    Future<List<Map<String, dynamic>>> Function() source,
  ) async {
    final List<Map<String, dynamic>> rows;
    try {
      rows = await source();
    } on Object {
      return; // Durability is best-effort (E5); the store stays usable.
    }
    for (final row in rows) {
      final id = row['id'];
      final content = row['content'];
      if (id is! String || id.isEmpty || content is! String) continue;
      final status = row['status'] == 'partial'
          ? AgentArtifactStatus.partial
          : AgentArtifactStatus.complete;
      final childId = row['childId'];
      final chars = row['chars'];
      store.restoreOutput(
        id,
        content,
        meta: AgentArtifactMeta(
          status: status,
          childId: childId is String ? childId : '',
          reportId: row['reportId'] is String
              ? row['reportId'] as String
              : null,
          chars: chars is int ? chars : content.length,
          bytes: utf8.encode(content).length,
        ),
      );
    }
  }

  /// Appends one durable row for a completed spill (best-effort: a
  /// failed write is swallowed — the in-session artifact and its pointer
  /// are already live; only the post-resume lifetime was lost).
  void _persistRow(
    String id,
    String redacted,
    AgentArtifactStatus status,
    String childId,
    String? reportId,
  ) {
    final sink = _persistArtifact;
    if (sink == null) return;
    unawaited(
      sink({
        'id': id,
        'content': redacted,
        'status': status.name,
        'childId': childId,
        'reportId': ?reportId,
        'chars': redacted.length,
      }).catchError((Object _) {}),
    );
  }

  /// The delivery budget (pointer and status overhead count toward it).
  int get cap => manager.maxReplyChars;

  /// Per-child, per-report chunk ledgers (Core flow C bookkeeping).
  final _ledgers = <String, Map<String, _ChunkLedger>>{};

  /// Why a deliverable could not be stored (E5) — surfaced explicitly, no
  /// raw bytes and no false pointer ride with it.
  String? unavailableReason;

  /// Redacts [text] through the wired pipeline (I3: mandatory
  /// pre-persistence gate).
  String _redactOrThrow(String text) => _redact == null ? text : _redact(text);

  /// Records an artifact: content is ALREADY redacted. When
  /// [checkEnvelopeFit] is true, throws [StateError] BEFORE anything is
  /// written when the cap cannot hold the envelope (AC8). Store failures
  /// propagate — the caller degrades, never a raw fallback.
  DeliverableRecord _persist({
    required String childId,
    required String redacted,
    required AgentArtifactStatus status,
    String? reportId,
    int? partIndex,
    String idBase = 'report',
    bool checkEnvelopeFit = true,
  }) {
    final id = store.allocateId('$childId-$idBase');
    if (checkEnvelopeFit) {
      final overhead =
          _statusLine(status, id, redacted.length, redacted).length + 2;
      if (overhead >= cap) {
        throw StateError(
          'maxReplyChars ($cap) cannot hold a deliverable envelope '
          '(overhead $overhead) — raise the cap; refusing to emit a '
          'malformed pointer',
        );
      }
    }
    store.put(id, redacted);
    final meta = AgentArtifactMeta(
      status: status,
      childId: childId,
      chars: redacted.length,
      bytes: utf8.encode(redacted).length,
      reportId: reportId,
    );
    store.recordArtifact(id, meta);
    // gh-1956 AC6: one durable row per spill — best-effort, after the
    // in-session artifact is live.
    _persistRow(id, redacted, status, childId, reportId);
    return DeliverableRecord.artifact(
      childId: childId,
      outputId: id,
      status: status,
      reportId: reportId,
      partIndex: partIndex,
      chars: redacted.length,
      bytes: meta.bytes!,
    );
  }

  /// The envelope status line for a stored deliverable (deterministic, so
  /// the fit check can run BEFORE anything is persisted). Carries the
  /// completeness marker with the char AND byte count (gh-1956).
  String _statusLine(
    AgentArtifactStatus status,
    String id,
    int chars,
    String stored,
  ) => switch (status) {
    AgentArtifactStatus.complete =>
      '[deliverable complete: agent://$id '
          '($chars chars, ${utf8.encode(stored).length} bytes)]',
    AgentArtifactStatus.partial =>
      '[deliverable PARTIAL — salvaged from an output-truncated call: '
          'agent://$id ($chars chars, ${utf8.encode(stored).length} bytes)]',
  };

  /// Core flow A for the `reply` channel: when [body] fits the budget,
  /// returns null (direct delivery, byte-identical, no artifact — AC1);
  /// otherwise stores the full redacted body and returns the envelope
  /// record. [reportId]/[reportParts] carry the final chunk manifest when
  /// the child uses the chunk protocol; the manifest verdict is recorded
  /// either way (E10).
  ///
  /// Throws [StateError] when the cap cannot hold a valid envelope — an
  /// explicit size/configuration error raised BEFORE anything is
  /// persisted, never a malformed pointer (AC8).
  DeliverableRecord? deliverReply(
    String childId,
    String body, {
    String? reportId,
    int? reportParts,
  }) {
    final cleanReportId = _cleanReportId(reportId);
    _recordManifest(
      childId,
      body,
      reportId: cleanReportId,
      reportParts: reportParts,
    );
    // gh-1956: spill gating happens BEFORE the size check — the kill
    // switch (or a missing spill capability) falls through to the
    // caller's legacy delivery with the chunk protocol as the fallback.
    if (!spillEnabled) return null;
    if (body.length <= cap) return null;
    final redacted = _redactOrThrow(body);
    final record = _persist(
      childId: childId,
      redacted: redacted,
      status: AgentArtifactStatus.complete,
      reportId: cleanReportId,
    );
    manager[childId]?.deliverables.add(record);
    return record;
  }

  /// Core flow A + chunk observation for the `agent_message` channel.
  /// Returns null when [target] is NOT a same-session recipient (A2A
  /// `name@machine`, cross-instance mailboxes, hub-only ids) — those keep
  /// the existing bare capping because they cannot resolve a same-session
  /// `agent://` pointer (E11). Returns null for in-budget bodies too
  /// (direct delivery, after ledger observation).
  DeliverableRecord? deliverAgentMessage({
    required String childId,
    required String target,
    required String body,
    String? reportId,
    int? partIndex,
  }) {
    if (!_isSameSession(target)) return null;
    final cleanReportId = _cleanReportId(reportId);
    if (cleanReportId != null && partIndex != null) {
      _observeChunk(childId, cleanReportId, partIndex);
      if (body.length <= cap) {
        final record = DeliverableRecord.chunk(
          childId: childId,
          reportId: cleanReportId,
          partIndex: partIndex,
          chars: body.length,
        );
        manager[childId]?.deliverables.add(record);
        return record;
      }
    }
    // gh-1956: the spill gate sits before the size check — under the
    // kill switch an over-cap part keeps the legacy bare cap and the
    // tools teach the chunk fallback.
    if (!spillEnabled) return null;
    if (body.length <= cap) return null;
    final redacted = _redactOrThrow(body);
    final record = _persist(
      childId: childId,
      redacted: redacted,
      status: AgentArtifactStatus.complete,
      reportId: cleanReportId,
      partIndex: partIndex,
      idBase: 'chunk',
    );
    manager[childId]?.deliverables.add(record);
    return record;
  }

  /// Core flow B: the agent loop's truncated-call hook. Fails nothing,
  /// executes nothing (I2) — captures salvage-parsed deliverable TEXT as a
  /// partial artifact when the call is a deliverable and its `message`
  /// field holds usable text (E2: empty/absent/malformed fields create no
  /// artifact). The failure itself always stands.
  ///
  /// The loop awaits this hook, and it awaits the memoized
  /// [ensureRestored] BEFORE the id-allocating persist (gh-1956 review):
  /// every spill path — `reply`, `agent_message`, and the salvage hook
  /// alike — re-seeds a resumed session's ids first, so a restored row can
  /// never be shadowed by a same-id allocation racing the boot kick.
  ///
  /// AC11 scope: [SubagentHandle.hadTruncatedDeliverable] means "an
  /// output-truncated DELIVERABLE call was recorded" — the flag is set
  /// only past the allowlist check, so a truncated `bash`/`read` call
  /// never produces a report-attempt claim in the tier-2 note.
  Future<void> captureSalvaged(String childId, ToolCall call) async {
    if (!deliverableToolNames.contains(call.name)) return;
    manager[childId]?.hadTruncatedDeliverable = true;
    final text = call.arguments['message'];
    if (text is! String || text.trim().isEmpty) return;
    // Restore-before-delivery covers the salvage path too (gh-1956
    // review): await the memoized restore so the id allocator already
    // holds the resumed ids when the partial artifact is persisted.
    await ensureRestored();
    try {
      final redacted = _redactOrThrow(text);
      // No envelope fit check: a partial artifact is delivered via the
      // result's pointer line, not through a bounded envelope.
      final record = _persist(
        childId: childId,
        redacted: redacted,
        status: AgentArtifactStatus.partial,
        reportId: _cleanReportId(
          call.arguments['report_id'] is String
              ? call.arguments['report_id'] as String
              : null,
        ),
        checkEnvelopeFit: false,
      );
      manager[childId]?.deliverables.add(record);
    } on Object {
      // E5: redaction failed — no artifact, no invented completion, no
      // raw fallback. The original truncation error remains the only
      // recovery signal; the recorded [SubagentHandle
      // .hadTruncatedDeliverable] flag drives the tier-2 fallback.
    }
  }

  /// Child-selected ids are interpolated into parent-visible render lines
  /// and ledger keys — strip structural characters so a hostile-looking id
  /// cannot inject synthetic lines (review hygiene, issue #1829).
  String? _cleanReportId(String? reportId) =>
      reportId?.replaceAll(RegExp(r'[\r\n\[\]]'), '_');

  /// Whether [target] resolves INSIDE this session's shared store: a local
  /// child handle or the parent inbox. Cross-instance mailboxes (`/`),
  /// A2A addresses (`@`), and hub-only ids cannot resolve the pointer and
  /// keep the existing delivery (E11).
  bool _isSameSession(String target) =>
      !target.contains('@') &&
      !target.contains('/') &&
      (target == manager.selfId || manager[target] != null);

  void _observeChunk(String childId, String reportId, int partIndex) {
    _ledgers.putIfAbsent(childId, () => {})[reportId] ??= _ChunkLedger();
    _ledgers[childId]![reportId]!.observe(partIndex);
  }

  /// Validates the final chunk manifest (Core flow C step 3, E10): the
  /// verdict is the harness's — every declared part observed, none
  /// duplicated, none out of order — never the child's label. Recorded
  /// only when the child actually declares a manifest (reportId present).
  void _recordManifest(
    String childId,
    String body, {
    required String? reportId,
    required int? reportParts,
  }) {
    if (reportId == null) return;
    final ledger = _ledgers[childId]?[reportId];
    if (ledger == null || reportParts == null) {
      manager[childId]?.deliverables.add(
        DeliverableRecord.manifest(
          childId: childId,
          reportId: reportId,
          partCount: reportParts ?? ledger?.parts.length ?? 0,
          complete: false,
          missingParts: reportParts == null
              ? const []
              : ledger?.missingOf(reportParts) ?? const [],
          verdictNote: reportParts == null
              ? 'manifest does not declare the part count'
              : 'no parts were observed for this report id',
          chars: body.length,
        ),
      );
      return;
    }
    final missing = ledger.missingOf(reportParts);
    final note = StringBuffer();
    if (ledger.duplicates > 0) {
      note.write('${ledger.duplicates} duplicate part(s); ');
    }
    if (ledger.outOfOrder > 0) note.write('parts arrived out of order; ');
    manager[childId]?.deliverables.add(
      DeliverableRecord.manifest(
        childId: childId,
        reportId: reportId,
        partCount: reportParts,
        complete:
            missing.isEmpty && ledger.duplicates == 0 && ledger.outOfOrder == 0,
        missingParts: missing,
        verdictNote: note.toString().trim(),
        chars: body.length,
      ),
    );
  }

  /// The parent-visible envelope for a stored deliverable (Core flow A):
  /// bounded head excerpt + resolvable pointer + explicit completeness,
  /// sized to fit [cap]. The fit was verified before persistence; this
  /// formats it.
  ///
  /// I3: the excerpt is sliced from the STORED artifact text — the exact
  /// redacted bytes `agent://` resolution returns — never from the raw
  /// pre-pipeline payload. Redaction runs before ANY parent-visible
  /// surface, envelope included.
  String envelopeText(DeliverableRecord record) {
    final stored = store.get(record.outputId!)!;
    final statusLine = _statusLine(
      record.status!,
      record.outputId!,
      record.chars,
      stored,
    );
    final excerptEnd = _naturalExcerptEnd(stored, cap - statusLine.length - 2);
    final excerpt = stored.substring(0, excerptEnd);
    return '$excerpt…\n$statusLine';
  }

  /// The excerpt end for the envelope: surrogate-pair safe (never a cut
  /// mid-rune) and, when the text continues past the cut, ending at a
  /// NATURAL boundary when one is nearby (gh-1956 edge case) — a
  /// paragraph break (blank line) within a quarter of the budget, else
  /// any line break within an eighth, else the bounded raw cut. The
  /// windows guarantee at least 3/4 of the excerpt budget survives.
  static int _naturalExcerptEnd(String text, int max) {
    final hardEnd = _safeExcerptEnd(text, max);
    if (hardEnd >= text.length) return hardEnd;
    const paragraph = '\n\n';
    const line = '\n';
    final paragraphWindow = max >= 4 ? max >> 2 : 1;
    final lineWindow = max >= 8 ? max >> 3 : 1;
    // Paragraph first (the wider window), then any line break.
    final paragraphAt = text.lastIndexOf(paragraph, hardEnd - 1);
    if (paragraphAt > 0 && paragraphAt >= hardEnd - paragraphWindow) {
      // End right after the paragraph's own newline: a complete
      // paragraph, the blank line dropped from the excerpt.
      return _safeExcerptEnd(text, paragraphAt + 1);
    }
    final lineAt = text.lastIndexOf(line, hardEnd - 1);
    if (lineAt > 0 && lineAt >= hardEnd - lineWindow) {
      return _safeExcerptEnd(text, lineAt);
    }
    return hardEnd;
  }

  /// The largest excerpt end ≤ [max] that does not split a surrogate pair.
  static int _safeExcerptEnd(String text, int max) {
    var end = max < text.length ? max : text.length;
    if (end > 0 &&
        end < text.length &&
        text.codeUnitAt(end - 1) >= 0xD800 &&
        text.codeUnitAt(end - 1) <= 0xDBFF) {
      end--;
    }
    return end;
  }
}
